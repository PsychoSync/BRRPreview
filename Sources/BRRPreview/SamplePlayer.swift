import AVFoundation
import BRRCore

enum SamplePlayerError: LocalizedError {
    case bufferUnavailable

    var errorDescription: String? {
        switch self {
        case .bufferUnavailable: return "Could not allocate an audio buffer."
        }
    }
}

@MainActor
final class SamplePlayer {
    var onFinished: (() -> Void)?

    /// Varispeed range supported by AVAudioUnitVarispeed.
    static let rateRange = 0.25...4.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let format: AVAudioFormat
    /// Bumped on every play and stop so stale completion callbacks are ignored.
    private var generation = 0

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
        generation += 1
        let token = generation
        node.stop()
        varispeed.rate = Float(min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound))
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        var intro: ArraySlice<Int16> = []
        var body = samples[...]
        if loop, let loopStart, loopStart < samples.count {
            intro = samples[..<loopStart]
            body = samples[loopStart...]
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
