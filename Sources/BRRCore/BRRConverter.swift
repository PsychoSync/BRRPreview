import Foundation

/// Result of converting an edited sample to BRR at a chosen output rate.
public struct BRRConversion: Equatable {
    public var encoding: BRREncoder.Encoding
    public var outputRate: Double

    /// The `.brr` file: a two-byte loop offset followed by the BRR blocks.
    public var file: [UInt8] { BRREncoder.file(encoding) }

    /// DSP pitch register that plays the sample back at its original speed.
    public var pitchRegister: Int { BRRConverter.pitchRegister(for: outputRate) }

    /// Length of the encoded sample in samples at `outputRate`.
    public var sampleCount: Int { encoding.blockCount * BRRDecoder.samplesPerBlock }
}

public enum BRRConverter {
    /// Output rates offered in the editor. 32 kHz is the SPC700's native rate.
    public static let outputRates: [Double] = [32_000, 22_050, 16_000, 11_025, 8_000]
    public static let defaultOutputRate: Double = 32_000

    public static func convert(_ sample: EditableSample, outputRate: Double) -> BRRConversion {
        let resampled = Resampler.resample(sample.samples, from: sample.sourceRate, to: outputRate)
        let loop = sample.loopStart.map { Int((Double($0) * outputRate / sample.sourceRate).rounded()) }
        let encoding = BRREncoder.encode(resampled, loopStart: loop)
        return BRRConversion(encoding: encoding, outputRate: outputRate)
    }

    /// Pitch register for a given playback rate. 0x1000 corresponds to 32 kHz.
    public static func pitchRegister(for rate: Double) -> Int {
        Int((rate / BRRDecoder.sampleRate * 4096).rounded())
    }
}
