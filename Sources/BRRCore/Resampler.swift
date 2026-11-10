import Foundation

/// Band-limited sample-rate conversion using a Blackman-windowed sinc kernel.
/// When downsampling, the cutoff drops below the new Nyquist frequency to avoid aliasing.
public enum Resampler {
    public static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return input }

        let ratio = targetRate / sourceRate
        let outputCount = Int((Double(input.count) * ratio).rounded())
        // Cutoff in cycles per source sample, with a small margin below Nyquist.
        let cutoff = 0.5 * min(1, ratio) * 0.95
        // Wider kernel for lower cutoffs, so the transition band stays narrow.
        let halfWidth = Int((16 / (2 * cutoff)).rounded(.up))

        var output = [Float](repeating: 0, count: outputCount)
        for j in 0..<outputCount {
            let position = Double(j) / ratio
            let centre = Int(position.rounded(.down))
            var sum = 0.0
            var weightSum = 0.0
            for k in max(0, centre - halfWidth + 1)...min(input.count - 1, centre + halfWidth) {
                let distance = position - Double(k)
                let u = distance / Double(halfWidth)
                let weight = blackman(u) * 2 * cutoff * sinc(2 * cutoff * distance)
                sum += Double(input[k]) * weight
                weightSum += weight
            }
            output[j] = weightSum != 0 ? Float(sum / weightSum) : 0
        }
        return output
    }

    private static func sinc(_ x: Double) -> Double {
        x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
    }

    private static func blackman(_ u: Double) -> Double {
        guard abs(u) < 1 else { return 0 }
        return 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u)
    }
}
