import Accelerate
import AVFoundation
import BRRCore
import CSpcEmu
import Foundation

struct SPCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// State shared with the audio render thread. The emulator serializes its own calls, and `emu` is only
/// reassigned while the engine is stopped.
final class SPCEmuHandle: @unchecked Sendable {
    static let renderChunk = 1024

    var emu: OpaquePointer?
    let scratch: UnsafeMutablePointer<Int16>

    init() {
        scratch = .allocate(capacity: 2 * Self.renderChunk)
        scratch.initialize(repeating: 0, count: 2 * Self.renderChunk)
    }

    deinit {
        scratch.deallocate()
    }
}

/// The DSP's native output rate. Pitch register 0x1000 plays at this rate.
private let spcSampleRate = 32_000

struct SPCVoiceState: Identifiable, Equatable {
    static let barCount = 32

    let index: Int
    /// Source directory index (SRCN) the voice is currently playing.
    var sampleIndex: Int
    /// Raw 14-bit pitch register. 0x1000 is 32 kHz.
    var pitch: Int
    /// Envelope height, 0...127.
    var envelope: Int
    /// Log-spaced spectrum bars, each normalized to 0...1.
    var bars: [Float]

    var id: Int { index }

    static func silent(index: Int) -> SPCVoiceState {
        SPCVoiceState(index: index, sampleIndex: 0, pitch: 0, envelope: 0,
                      bars: [Float](repeating: 0, count: barCount))
    }

    var frequency: Double { Double(pitch) * Double(spcSampleRate) / 4096 }

    /// A voice is sounding when it has both a pitch and an envelope.
    var isSounding: Bool { pitch > 0 && envelope > 0 }
}

/// A playing SPC file. Voices are the DSP's eight hardware channels; each shows the sample it currently plays.
@MainActor
final class SPCSession: ObservableObject {
    static let sampleRate = spcSampleRate
    static let fileSize = Int(SPC_FILE_SIZE)
    static let magic = Array("SNES-SPC700 Sound File Data".utf8)
    static let ramOffset = 0x100
    static let dspOffset = 0x10100

    private static let fftSize = 1024
    private static let spectrumFPS = 30.0
    private static let frameDuration = 1 / spectrumFPS

    let url: URL
    @Published private(set) var songTitle = ""
    @Published private(set) var gameTitle = ""
    @Published private(set) var authorName = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var voices = (0..<Int(SPC_VOICE_COUNT)).map { SPCVoiceState.silent(index: $0) }
    @Published private(set) var mutedVoices: Set<Int> = []
    @Published private(set) var soloVoices: Set<Int> = []
    /// Voices (default) or tracks. Track mode applies mute and solo to the sample each voice is playing.
    @Published var viewMode: SPCViewMode = .voices {
        didSet { pushMask() }
    }
    /// One entry per sample heard since the last restart, in first-heard order.
    @Published private(set) var tracks: [SPCTrackState] = []
    @Published var sampleNames: [Int: String] = [:]
    @Published var isExtracting = false
    /// Keyed by sample index (SRCN), so a track's mute follows its sound across voices.
    @Published private(set) var mutedTracks: Set<Int> = []
    @Published private(set) var soloTracks: Set<Int> = []
    /// Seconds of song time since the last restart. Paused time does not advance it.
    @Published private(set) var playbackTime: Double = 0
    @Published var volume: Float = 0.8 {
        didSet { sourceNode.volume = volume }
    }
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    /// The original SPC image with every RAM edit applied. Used to restart the song and to build a saved file.
    private(set) var patchedFile: [UInt8]
    /// Extended ID666 tags from the loaded file. Saved files start from these, and the save sheet can change them.
    var extendedTags = SPCExtendedTags()
    let handle = SPCEmuHandle()

    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private var timer: Timer?
    private let fft: vDSP.DiscreteFourierTransform<Float>?
    private let hann: [Float]

    init(url: URL) throws {
        self.url = url
        let data = [UInt8](try Data(contentsOf: url))
        // Files may carry an xid6 metadata block after the emulator image, so the size is only a minimum.
        guard data.count >= Self.fileSize, data.starts(with: Self.magic) else {
            throw SPCError(message: "\(url.lastPathComponent) is not a valid SPC file (\(data.count) bytes).")
        }
        patchedFile = data
        extendedTags = SPCExtendedTags(tail: Array(data.dropFirst(Self.fileSize)))

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 2)!
        let handle = self.handle
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            Self.render(handle: handle, frames: Int(frameCount), bufferList: bufferList)
            return noErr
        }

        fft = try? vDSP.DiscreteFourierTransform(previous: nil, count: Self.fftSize, direction: .forward,
                                                 transformType: .complexComplex, ofType: Float.self)
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                           count: Self.fftSize, isHalfWindow: false)

        handle.emu = try Self.openEmu(data: patchedFile)
        readTrackInfo()
        sourceNode.volume = volume

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        pushMask()
    }

    /// Stops audio and releases the emulator. Call before dropping the session.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        engine.stop()
        isPlaying = false
        closeEmu()
    }

    // MARK: Transport

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard handle.emu != nil else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            isPlaying = true
            startTimer()
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
        }
    }

    func pause() {
        engine.pause()
        isPlaying = false
        stopTimer()
    }

    /// Stops playback and restarts the song from the beginning, keeping any sample replacements.
    func stop() {
        engine.stop()
        isPlaying = false
        stopTimer()
        do {
            try restart()
        } catch {
            errorMessage = error.localizedDescription
        }
        voices = (0..<Int(SPC_VOICE_COUNT)).map { SPCVoiceState.silent(index: $0) }
        tracks = []
        playbackTime = 0
    }

    // MARK: Mute and solo

    func toggleMute(_ voice: Int) {
        if mutedVoices.contains(voice) {
            mutedVoices.remove(voice)
        } else {
            mutedVoices.insert(voice)
        }
        pushMask()
    }

    func toggleSolo(_ voice: Int) {
        if soloVoices.contains(voice) {
            soloVoices.remove(voice)
        } else {
            soloVoices.insert(voice)
        }
        pushMask()
    }

    func toggleTrackMute(_ sourceIndex: Int) {
        if mutedTracks.contains(sourceIndex) {
            mutedTracks.remove(sourceIndex)
        } else {
            mutedTracks.insert(sourceIndex)
        }
        pushMask()
    }

    func toggleTrackSolo(_ sourceIndex: Int) {
        if soloTracks.contains(sourceIndex) {
            soloTracks.remove(sourceIndex)
        } else {
            soloTracks.insert(sourceIndex)
        }
        pushMask()
    }

    /// Builds the emulator mute mask for the current view mode.
    private func pushMask() {
        var mask = 0
        for voice in 0..<Int(SPC_VOICE_COUNT) where isSilenced(voice) {
            mask |= 1 << voice
        }
        guard let emu = handle.emu else { return }
        spc_set_mute_mask(emu, Int32(mask))
    }

    /// Voices are silenced when muted, or when any voice is soloed and this one is not.
    /// In track mode the same rules apply to the sample each voice is playing, as of the last spectrum tick.
    private func isSilenced(_ voice: Int) -> Bool {
        switch viewMode {
        case .voices:
            let soloed = soloVoices.isEmpty || soloVoices.contains(voice)
            return mutedVoices.contains(voice) || !soloed
        case .tracks:
            let source = voices[voice].sampleIndex
            let soloed = soloTracks.isEmpty || soloTracks.contains(source)
            return mutedTracks.contains(source) || !soloed
        }
    }


    // MARK: RAM access

    func readRAM(_ address: Int, count: Int) -> [UInt8]? {
        guard let emu = handle.emu, count >= 0 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        guard spc_read_ram(emu, Int32(address), &out, Int32(count)) == 0 else { return nil }
        return out
    }

    /// Writes into live RAM and mirrors the change into `patchedFile`, so the edit survives a restart.
    func writeRAM(_ address: Int, _ bytes: [UInt8]) throws {
        guard address >= 0, address + bytes.count <= 0x10000 else {
            throw SPCError(message: "Address range \(address)..<\(address + bytes.count) is outside SPC RAM.")
        }
        if let emu = handle.emu {
            guard spc_write_ram(emu, Int32(address), bytes, Int32(bytes.count)) == 0 else {
                throw SPCError(message: "The emulator rejected a RAM write at \(address).")
            }
        }
        patchedFile.replaceSubrange((Self.ramOffset + address)..<(Self.ramOffset + address + bytes.count),
                                    with: bytes)
    }

    func readDSP(_ register: Int) -> Int {
        guard let emu = handle.emu else { return 0 }
        return Int(spc_read_dsp(emu, Int32(register & 0x7F)))
    }

    /// The live DSP sample directory page (register DIR, times 256).
    var directoryBase: Int { readDSP(0x5D) << 8 }

    /// The current state as an SPC file: this is a snapshot of the live song, not the start of the track.
    /// The extended tags are appended after the image, as the format expects.
    func savedImage(tags: SPCExtendedTags) throws -> [UInt8] {
        guard let emu = handle.emu else { throw SPCError(message: "No SPC is loaded.") }
        var out = [UInt8](repeating: 0, count: Self.fileSize)
        let written = spc_save(emu, &out, out.count)
        guard written == Self.fileSize else {
            throw SPCError(message: "Could not serialize the SPC state.")
        }
        return out + tags.serialized()
    }

    // MARK: Internals

    private static func openEmu(data: [UInt8]) throws -> OpaquePointer {
        var err = [CChar](repeating: 0, count: 256)
        let emu = data.withUnsafeBufferPointer { buffer in
            spc_open(buffer.baseAddress, buffer.count, Int32(sampleRate), &err, Int32(err.count))
        }
        guard let emu else {
            throw SPCError(message: String(cString: err))
        }
        guard spc_start(emu) == 0 else {
            spc_close(emu)
            throw SPCError(message: "The SPC could not be started.")
        }
        return emu
    }

    private func restart() throws {
        closeEmu()
        handle.emu = try Self.openEmu(data: patchedFile)
        pushMask()
    }

    private func closeEmu() {
        if let emu = handle.emu {
            handle.emu = nil
            spc_close(emu)
        }
    }

    private func readTrackInfo() {
        guard let emu = handle.emu else { return }
        var info = SpcTrackInfo()
        guard spc_track_info(emu, &info) == 0 else { return }
        songTitle = Self.text(info.song)
        gameTitle = Self.text(info.game)
        authorName = Self.text(info.author)
    }

    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.spectrumFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshVoices()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshVoices() {
        guard let emu = handle.emu else { return }
        voices = (0..<voices.count).map { voice in
            let base = voice * 0x10
            let pitch = readDSP(base + 2) | ((readDSP(base + 3) & 0x3F) << 8)
            return SPCVoiceState(index: voice,
                                 sampleIndex: readDSP(base + 4),
                                 pitch: pitch,
                                 envelope: readDSP(base + 8) & 0x7F,
                                 bars: spectrum(emu, voice: voice))
        }
        let now = playbackTime
        playbackTime += Self.frameDuration
        SPCTrackTracker.update(&tracks, voices: voices, time: now, frameDuration: Self.frameDuration)
        if viewMode == .tracks {
            pushMask()
        }
    }

    private func spectrum(_ emu: OpaquePointer, voice: Int) -> [Float] {
        guard let fft else { return [Float](repeating: 0, count: SPCVoiceState.barCount) }
        var tap = [Int16](repeating: 0, count: Int(SPC_TAP_SIZE))
        _ = spc_copy_voice_tap(emu, Int32(voice), &tap, Int32(tap.count))

        let samples = tap.suffix(Self.fftSize).map { Float($0) / 32_768 }
        let windowed = vDSP.multiply(samples, hann)
        let (real, imaginary) = fft.transform(real: windowed,
                                              imaginary: [Float](repeating: 0, count: Self.fftSize))

        let binCount = Self.fftSize / 2
        let scale = 1 / Float(binCount)
        var magnitudes = [Float](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            magnitudes[bin] = hypot(real[bin], imaginary[bin]) * scale
        }

        // Log-spaced bars from bin 1 up to the top bin, so low frequencies get room on screen.
        let top = Double(binCount - 1)
        var bars = [Float](repeating: 0, count: SPCVoiceState.barCount)
        for bar in 0..<SPCVoiceState.barCount {
            let lower = Int(pow(top, Double(bar) / Double(SPCVoiceState.barCount)))
            let upper = max(lower + 1, Int(pow(top, Double(bar + 1) / Double(SPCVoiceState.barCount))))
            var peak: Float = 0
            for bin in lower..<min(upper, binCount) {
                peak = max(peak, magnitudes[bin])
            }
            let decibels = 20 * log10(max(peak, 1e-6))
            bars[bar] = min(max((decibels + 60) / 60, 0), 1)
        }
        return bars
    }

    /// Runs on the audio render thread.
    private static func render(handle: SPCEmuHandle, frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        var done = 0
        while done < frames {
            let count = min(SPCEmuHandle.renderChunk, frames - done)
            if let emu = handle.emu, spc_play(emu, Int32(count), handle.scratch) == 0 {
                for i in 0..<count {
                    left[done + i] = Float(handle.scratch[2 * i]) / 32_768
                    right[done + i] = Float(handle.scratch[2 * i + 1]) / 32_768
                }
            } else {
                for i in 0..<count {
                    left[done + i] = 0
                    right[done + i] = 0
                }
            }
            done += count
        }
    }
}
