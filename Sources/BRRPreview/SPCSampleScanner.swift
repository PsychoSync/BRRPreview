import BRRCore
import CSpcEmu
import Foundation

enum SPCSampleScanner {
    static func scan(image: [UInt8], duration: Double) throws -> [SPCSampleSnapshot] {
        guard duration.isFinite, duration > 0, duration <= 3600 else {
            throw SPCError(message: "Choose a scan length greater than 0 and no more than 60 minutes.")
        }
        var error = [CChar](repeating: 0, count: 256)
        guard let emu = spc_open(image, image.count, 32_000, &error, Int32(error.count)) else {
            throw SPCError(message: String(cString: error))
        }
        defer { spc_close(emu) }
        spc_begin_sample_capture(emu)
        guard spc_start(emu) == 0 else { throw SPCError(message: "Couldn't start the sample scan.") }
        let frameCount = Int(duration * 32_000)
        var buffer = [Int16](repeating: 0, count: 2048)
        for offset in stride(from: 0, to: frameCount, by: 1024) {
            try Task.checkCancellation()
            guard spc_play(emu, Int32(min(1024, frameCount - offset)), &buffer) == 0 else {
                throw SPCError(message: "The emulator failed while scanning the song.")
            }
        }
        return try (0..<spc_captured_sample_count(emu)).map { index in
            var info = SpcCapturedSample()
            var bytes = [UInt8](repeating: 0, count: 0x10000)
            let count = spc_copy_captured_sample(emu, index, &info, &bytes, Int32(bytes.count))
            guard count > 0 else { throw SPCError(message: "Couldn't read a sample found by the scan.") }
            let data = Array(bytes.prefix(Int(count)))
            let loop = data[data.count - 9] & 2 != 0
                ? SampleReplacement.loopBlock(start: Int(info.start), loopAddress: Int(info.loop_address),
                                              blockCount: Int(info.block_count)) : nil
            return SPCSampleSnapshot(voice: nil, sourceIndex: Int(info.source_index),
                                     directoryAddress: Int(info.directory_address), start: Int(info.start),
                                     loopAddress: Int(info.loop_address), data: data, blockCount: Int(info.block_count),
                                     loopBlock: loop, frequency: PitchDetector.fundamentalFrequency(
                                        samples: BRRDecoder.decode(data).samples, sampleRate: BRRDecoder.sampleRate))
        }
    }
}
