import BRRCore
import Foundation

/// A monophonic piano audition with a latched key, loop and independent monitor volume.
@MainActor
final class SampleAudition: ObservableObject {
    @Published private(set) var samples: [Int16] = []
    @Published private(set) var loopStart: Int?
    @Published private(set) var isPlaying = false
    @Published var note: Int {
        didSet { if note != oldValue { updateRate() } }
    }
    @Published var loopEnabled = false {
        didSet { if loopEnabled != oldValue, isPlaying { start() } }
    }
    @Published var hold = false {
        didSet {
            guard hold != oldValue else { return }
            hold ? start() : stop()
        }
    }
    @Published var volume: Float = 0.8 {
        didSet { player.volume = volume }
    }
    @Published private(set) var errorMessage: String?
    var pitchMultiplier = 1.0 {
        didSet { if pitchMultiplier != oldValue { updateRate() } }
    }
    let referenceFrequency: Double
    var rate: Double { Note.frequency(midi: Double(note)) / referenceFrequency * pitchMultiplier }
    private let player = SamplePlayer()

    init(referenceFrequency: Double, note: Int) {
        self.referenceFrequency = referenceFrequency
        self.note = note
        player.volume = volume
        player.onFinished = { [weak self] in self?.isPlaying = false }
    }

    func setSample(_ samples: [Int16], loopStart: Int?) {
        self.samples = samples
        self.loopStart = loopStart
        if isPlaying || hold { start() }
    }

    func playNote(_ midi: Int) {
        note = midi
        start()
    }

    func releaseNote(_ midi: Int) {
        if note == midi, !hold, loopEnabled { stop() }
    }

    func togglePlayback() {
        if isPlaying {
            hold = false
            stop()
        } else {
            start()
        }
    }

    func stop() {
        player.stop()
        isPlaying = false
    }

    func releaseAll() {
        hold = false
        stop()
    }

    private func start() {
        guard !samples.isEmpty else { return }
        do {
            try player.play(samples, loopStart: loopStart, loop: loopEnabled, rate: rate)
            isPlaying = true
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
        }
    }

    private func updateRate() {
        guard isPlaying else { return }
        do {
            try player.setRate(rate)
            errorMessage = nil
        } catch {
            stop()
            errorMessage = "Couldn't change pitch: \(error.localizedDescription)"
        }
    }
}
