import AVFoundation
import BRRCore
import CStbVorbis

enum AudioImportError: LocalizedError {
    case empty
    case unreadableVorbis
    case noBRRBlocks

    var errorDescription: String? {
        switch self {
        case .empty: return "The audio file contains no samples."
        case .unreadableVorbis: return "The Ogg Vorbis file couldn't be decoded."
        case .noBRRBlocks: return "The BRR file doesn't contain any complete blocks."
        }
    }
}

/// Reads an audio file as mono floating-point samples at the file's own sample rate.
enum AudioImport {
    static let extensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "ogg"]
    /// Files that can become a new sample: audio, plus BRR, which is decoded to its samples.
    static let sampleExtensions: Set<String> = extensions.union(["brr"])

    static func load(_ url: URL) throws -> EditableSample {
        switch url.pathExtension.lowercased() {
        case "ogg":
            return try loadVorbis(url)
        case "brr":
            return try loadBRR(url)
        default:
            break
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw AudioImportError.empty
        }
        try file.read(into: buffer)

        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else {
            throw AudioImportError.empty
        }
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for i in 0..<count {
                mono[i] += data[i]
            }
        }
        let scale = 1 / Float(channelCount)
        for i in 0..<count {
            mono[i] *= scale
        }
        return EditableSample(samples: mono, sourceRate: format.sampleRate)
    }

    /// BRR decodes to 32 kHz samples. The loop, if the file has one, carries over.
    private static func loadBRR(_ url: URL) throws -> EditableSample {
        let decoded = BRRDecoder.decodeFile([UInt8](try Data(contentsOf: url)))
        guard !decoded.samples.isEmpty else {
            throw AudioImportError.noBRRBlocks
        }
        return EditableSample(samples: decoded.samples.map { Float($0) / 32768 },
                              sourceRate: BRRDecoder.sampleRate,
                              loopStart: decoded.loopStart)
    }

    /// AVFoundation can't read Ogg Vorbis, so those files go through stb_vorbis.
    private static func loadVorbis(_ url: URL) throws -> EditableSample {
        var channels: Int32 = 0
        var sampleRate: Int32 = 0
        var output: UnsafeMutablePointer<Int16>?
        let frames = Int(stb_vorbis_decode_filename(url.path, &channels, &sampleRate, &output))
        guard frames > 0, channels > 0, let pcm = output else {
            throw AudioImportError.unreadableVorbis
        }
        defer { free(pcm) }

        let channelCount = Int(channels)
        let scale = 1 / (Float(channelCount) * 32768)
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += Float(pcm[i * channelCount + channel])
            }
            mono[i] = sum * scale
        }
        return EditableSample(samples: mono, sourceRate: Double(sampleRate))
    }
}
