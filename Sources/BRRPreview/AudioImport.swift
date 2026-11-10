import AVFoundation
import BRRCore
import CStbVorbis

enum AudioImportError: LocalizedError {
    case empty
    case unreadableVorbis

    var errorDescription: String? {
        switch self {
        case .empty: return "The audio file contains no samples."
        case .unreadableVorbis: return "The Ogg Vorbis file couldn't be decoded."
        }
    }
}

/// Reads an audio file as mono floating-point samples at the file's own sample rate.
enum AudioImport {
    static let extensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "ogg"]

    static func load(_ url: URL) throws -> EditableSample {
        if url.pathExtension.lowercased() == "ogg" {
            return try loadVorbis(url)
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
