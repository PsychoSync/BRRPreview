import Foundation

/// Decodes SNES BRR (Bit Rate Reduction) sample data into 16-bit PCM.
public enum BRRDecoder {
    public static let blockSize = 9
    public static let samplesPerBlock = 16
    /// Playback rate of the SPC700 DSP at its default pitch.
    public static let sampleRate = 32_000.0

    public struct Result: Equatable {
        public var samples: [Int16]
        public var blockCount: Int
        /// Decoding stops after the first block with the END bit set.
        public var hasEndFlag: Bool
        /// The LOOP bit from the END block. The loop address is stored in the
        /// SPC700 sample directory, not in the BRR data itself.
        public var hasLoopFlag: Bool
        /// Index of the first sample of the loop, when the file stores one.
        public var loopStart: Int? = nil
    }

    /// Decodes a `.brr` file. Files whose size is 2 mod 9 begin with a little-endian
    /// loop offset in bytes, and the BRR blocks follow it.
    public static func decodeFile(_ bytes: [UInt8]) -> Result {
        guard bytes.count % blockSize == 2 else { return decode(bytes) }
        let loopOffset = Int(bytes[0]) | Int(bytes[1]) << 8
        var result = decode(Array(bytes[2...]))
        if loopOffset % blockSize == 0 {
            let loopStart = loopOffset / blockSize * samplesPerBlock
            if loopStart < result.samples.count {
                result.loopStart = loopStart
            }
        }
        return result
    }

    public static func decode(_ bytes: [UInt8]) -> Result {
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count / blockSize * samplesPerBlock)
        var blockCount = 0
        var hasEndFlag = false
        var hasLoopFlag = false
        var p1 = 0
        var p2 = 0

        var offset = 0
        while offset + blockSize <= bytes.count {
            let header = bytes[offset]
            let range = Int(header >> 4)
            let filter = Int((header >> 2) & 0x3)
            blockCount += 1

            for byte in bytes[(offset + 1)..<(offset + blockSize)] {
                for nibble in [Int(byte >> 4), Int(byte & 0x0F)] {
                    let n = nibble >= 8 ? nibble - 16 : nibble
                    let s = reconstruct(nibble: n, range: range, filter: filter, p1: p1, p2: p2)
                    samples.append(Int16(s))
                    p2 = p1
                    p1 = s
                }
            }

            offset += blockSize
            if header & 0x01 != 0 {
                hasEndFlag = true
                hasLoopFlag = header & 0x02 != 0
                break
            }
        }

        return Result(samples: samples, blockCount: blockCount, hasEndFlag: hasEndFlag, hasLoopFlag: hasLoopFlag)
    }

    /// Output sample for one signed nibble, given the block's range and filter and the two previous outputs.
    /// The encoder uses this same function so its search matches what the hardware plays back.
    public static func reconstruct(nibble n: Int, range: Int, filter: Int, p1: Int, p2: Int) -> Int {
        // Ranges 13-15 are invalid on hardware and collapse to a sign-only value.
        var s = range <= 12 ? (n << range) >> 1 : (n >> 3) << 11
        // Predictor coefficients 15/16, 61/32 - 15/16, and 115/64 - 13/16, in integer form.
        switch filter {
        case 1: s += p1 + ((-p1) >> 4)
        case 2: s += (p1 << 1) + ((-(p1 + (p1 << 1))) >> 5) - p2 + (p2 >> 4)
        case 3: s += (p1 << 1) + ((-(p1 + (p1 << 2) + (p1 << 3))) >> 6) - p2 + ((p2 + (p2 << 1)) >> 4)
        default: break
        }
        return min(max(s, -32768), 32767)
    }
}
