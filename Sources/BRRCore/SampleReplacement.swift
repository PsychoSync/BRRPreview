import Foundation

/// Helpers for swapping a sample in SPC RAM: walking BRR chains, mapping loop addresses, and matching pitch.
public enum SampleReplacement {
    public enum PitchMode: String, CaseIterable, Identifiable, Sendable {
        /// Play the new sample at the root pitch of the sample it replaces.
        case matchOriginal = "Match original pitch"
        /// Play the new sample at its own detected pitch.
        case keepOwn = "Keep own pitch"

        public var id: String { rawValue }
    }

    /// Number of BRR blocks from `start` through the first block with the END bit set, or nil if none is found.
    public static func chainBlockCount(in ram: [UInt8], start: Int) -> Int? {
        var offset = start
        var count = 0
        while offset >= 0, offset + BRRDecoder.blockSize <= ram.count {
            count += 1
            if ram[offset] & 0x01 != 0 { return count }
            offset += BRRDecoder.blockSize
        }
        return nil
    }

    /// Block index a directory loop address points at, or nil when it lies outside the chain or isn't block-aligned.
    public static func loopBlock(start: Int, loopAddress: Int, blockCount: Int) -> Int? {
        let delta = loopAddress - start
        guard delta >= 0, delta % BRRDecoder.blockSize == 0 else { return nil }
        let block = delta / BRRDecoder.blockSize
        return block < blockCount ? block : nil
    }

    /// Declared source rate for a new sample. Played at the native 32 kHz (pitch register 0x1000), the
    /// sample sounds at `reference * 2^(cents/1200)`, where `reference` is the new sample's own pitch
    /// (keep own) or the original's root (match original). Unpitched samples only get the fine tuning.
    public static func declaredSourceRate(
        actualRate: Double,
        newFrequency: Double?,
        originalFrequency: Double?,
        mode: PitchMode,
        cents: Double
    ) -> Double {
        let fineTune = pow(2, cents / 1200)
        guard let newFrequency, newFrequency > 0 else { return actualRate * fineTune }
        let reference = (mode == .matchOriginal ? originalFrequency : nil) ?? newFrequency
        return actualRate * reference * fineTune / newFrequency
    }
}
