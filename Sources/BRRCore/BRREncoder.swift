import Foundation

/// Encodes PCM into SNES BRR blocks. Each block is fitted with the same arithmetic
/// that `BRRDecoder` uses, so the encoded data plays back the way it was measured.
public enum BRREncoder {
    public struct Encoding: Equatable {
        /// BRR block bytes, `BRRDecoder.blockSize` per block.
        public var data: [UInt8]
        public var blockCount: Int
        /// Index of the block where the loop begins, if the sample loops.
        public var loopBlock: Int?

        public init(data: [UInt8], blockCount: Int, loopBlock: Int?) {
            self.data = data
            self.blockCount = blockCount
            self.loopBlock = loopBlock
        }

        public var loopStart: Int? { loopBlock.map { $0 * BRRDecoder.samplesPerBlock } }

        /// Whether the loop offset fits the two-byte file header.
        public var loopHeaderFits: Bool {
            guard let loopBlock else { return true }
            return loopBlock * BRRDecoder.blockSize < Int(BRREncoder.noLoopMarker)
        }
    }

    /// Stored in the file header when the sample has no loop.
    public static let noLoopMarker: UInt16 = 0xFFFF

    /// Encodes mono samples in -1...1. `loopStart` is a sample index, rounded to the nearest block.
    public static func encode(_ samples: [Float], loopStart: Int? = nil) -> Encoding {
        let perBlock = BRRDecoder.samplesPerBlock
        let blockCount = max(1, (samples.count + perBlock - 1) / perBlock)

        var targets = [Int](repeating: 0, count: blockCount * perBlock)
        for (i, sample) in samples.enumerated() {
            targets[i] = min(max(Int((Double(sample) * 32768).rounded()), -32768), 32767)
        }

        let loopBlock = loopStart.map { min(max(($0 + perBlock / 2) / perBlock, 0), blockCount - 1) }

        var data: [UInt8] = []
        data.reserveCapacity(blockCount * BRRDecoder.blockSize)
        var p1 = 0
        var p2 = 0

        for block in 0..<blockCount {
            let target = Array(targets[(block * perBlock)..<((block + 1) * perBlock)])
            // Filter 0 ignores history, so the loop block decodes the same wherever the loop lands.
            let filters = block == loopBlock ? [0] : [0, 1, 2, 3]
            let fit = bestFit(target, p1: p1, p2: p2, filters: filters)

            var header = UInt8(fit.range << 4 | fit.filter << 2)
            if block == blockCount - 1 {
                header |= 0x01
                if loopBlock != nil { header |= 0x02 }
            }
            data.append(header)
            for i in stride(from: 0, to: perBlock, by: 2) {
                data.append(UInt8((fit.nibbles[i] & 0xF) << 4 | (fit.nibbles[i + 1] & 0xF)))
            }

            p2 = fit.outputs[perBlock - 2]
            p1 = fit.outputs[perBlock - 1]
        }

        return Encoding(data: data, blockCount: blockCount, loopBlock: loopBlock)
    }

    /// Wraps an encoding in the app's `.brr` file layout: a 2-byte little-endian loop offset
    /// in bytes (`noLoopMarker` when there is no loop), followed by the BRR blocks.
    /// A loop beyond the offset range is written as no loop; check `loopHeaderFits` first.
    public static func file(_ encoding: Encoding) -> [UInt8] {
        var header = noLoopMarker
        if encoding.loopHeaderFits, let loopBlock = encoding.loopBlock {
            header = UInt16(loopBlock * BRRDecoder.blockSize)
        }
        return [UInt8(header & 0xFF), UInt8(header >> 8)] + encoding.data
    }

    private struct BlockFit {
        var range: Int
        var filter: Int
        var error: Int
        var nibbles: [Int]
        var outputs: [Int]
    }

    private static func bestFit(_ target: [Int], p1: Int, p2: Int, filters: [Int]) -> BlockFit {
        var best: BlockFit?
        for filter in filters {
            for range in 0...12 {
                if let fit = fit(target, range: range, filter: filter, p1: p1, p2: p2, limit: best?.error ?? Int.max) {
                    best = fit
                }
            }
        }
        return best!
    }

    /// Greedy per-sample fit. Returns nil as soon as the error reaches `limit`.
    private static func fit(_ target: [Int], range: Int, filter: Int, p1: Int, p2: Int, limit: Int) -> BlockFit? {
        var nibbles = [Int](repeating: 0, count: target.count)
        var outputs = [Int](repeating: 0, count: target.count)
        var last = p1
        var beforeLast = p2
        var error = 0

        for i in target.indices {
            let t = target[i]
            let base = BRRDecoder.reconstruct(nibble: 0, range: range, filter: filter, p1: last, p2: beforeLast)
            // Each nibble step moves the output by about 2^range / 2, so the closest nibble is near this estimate.
            let estimate = Int((Double(t - base) * 2 / Double(1 << range)).rounded())
            let centre = min(max(estimate, -8), 7)

            var bestNibble = centre
            var bestOutput = 0
            var bestError = Int.max
            for n in max(centre - 1, -8)...min(centre + 1, 7) {
                let s = BRRDecoder.reconstruct(nibble: n, range: range, filter: filter, p1: last, p2: beforeLast)
                let e = (s - t) * (s - t)
                if e < bestError {
                    bestError = e
                    bestNibble = n
                    bestOutput = s
                }
            }

            error += bestError
            if error >= limit { return nil }
            nibbles[i] = bestNibble
            outputs[i] = bestOutput
            beforeLast = last
            last = bestOutput
        }

        return BlockFit(range: range, filter: filter, error: error, nibbles: nibbles, outputs: outputs)
    }
}
