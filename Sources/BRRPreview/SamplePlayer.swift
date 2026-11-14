import AVFoundation
import BRRCore

enum SamplePlayerError: LocalizedError {
    case bufferUnavailable
    case invalidRate

    var errorDescription: String? {
        switch self {
        case .bufferUnavailable: return "Could not allocate an audio buffer."
        case .invalidRate: return "The playback rate must be finite and greater than zero."
        }
    }
}

@MainActor
final class SamplePlayer {
    var onFinished: (() -> Void)?
    var volume: Float = 1 {
        didSet { node.volume = volume }
    }

    /// Varispeed range supported by AVAudioUnitVarispeed.
    static let rateRange = 0.25...4.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format: AVAudioFormat
    /// Bumped on every play and stop so stale completion callbacks are ignored.
    private var generation = 0
    private var currentSamples: [Int16] = []
    private var currentLoopStart: Int?
    private var currentLoop = false
    private var rateScale = 1.0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: BRRDecoder.sampleRate, channels: 1)!
        engine.attach(node)
        engine.attach(varispeed)
        engine.connect(node, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
    }

    /// Plays at `rate` times the native 32 kHz speed, which also scales pitch by the same factor.
    /// With `loop`, repeats from `loopStart` to the end, or the whole sample when there is no loop point.
    func play(_ samples: [Int16], loopStart: Int?, loop: Bool, rate: Double) throws {
        guard rate.isFinite, rate > 0 else { throw SamplePlayerError.invalidRate }
        currentSamples = samples
        currentLoopStart = loopStart
        currentLoop = loop
        generation += 1
        let token = generation
        node.stop()
        rateScale = Self.rateRange.contains(rate) ? 1 : pow(2, floor(log2(rate)))
        var pcm = samples
        var loopPoint = loopStart
        if rateScale != 1 {
            pcm = Resampler.resample(samples.map { Float($0) / 32768 },
                                     from: BRRDecoder.sampleRate * rateScale, to: BRRDecoder.sampleRate)
                .map { Int16(clamping: Int(($0 * 32768).rounded())) }
            loopPoint = loopStart.map { Int(Double($0) / rateScale) }
        }
        guard !pcm.isEmpty else { throw SamplePlayerError.bufferUnavailable }
        varispeed.rate = Float(rate / rateScale)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        var intro: ArraySlice<Int16> = []
        var body = pcm[...]
        if loop, let loopPoint, loopPoint >= 0, loopPoint < pcm.count {
            intro = pcm[..<loopPoint]
            body = pcm[loopPoint...]
        }
        if !intro.isEmpty {
            node.scheduleBuffer(try makeBuffer(intro), at: nil, options: [], completionHandler: nil)
        }
        node.scheduleBuffer(try makeBuffer(body), at: nil, options: loop ? .loops : [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.onFinished?()
            }
        }
        node.play()
    }

    /// Changes pitch without restarting a held note unless the resampling range changes.
    func setRate(_ rate: Double) throws {
        guard rate.isFinite, rate > 0 else { throw SamplePlayerError.invalidRate }
        if Self.rateRange.contains(rate / rateScale) {
            varispeed.rate = Float(rate / rateScale)
        } else {
            try play(currentSamples, loopStart: currentLoopStart, loop: currentLoop, rate: rate)
        }
    }

    func stop() {
        generation += 1
        node.stop()
    }

    private func makeBuffer(_ samples: ArraySlice<Int16>) throws -> AVAudioPCMBuffer {

        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw SamplePlayerError.bufferUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32768
        }
        return buffer
    }
}
