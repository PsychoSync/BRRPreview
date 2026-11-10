import Foundation

/// Estimates the fundamental frequency of a sample using normalized autocorrelation.
public enum PitchDetector {
    public static let minimumFrequency = 40.0
    public static let maximumFrequency = 2000.0

    /// Analysis window length, starting at the first sample above 1/8 of the peak.
    private static let windowLength = 8192
    /// Candidate lags must reach at least this fraction of the best correlation.
    private static let relativeThreshold = 0.9
    /// Below this correlation the signal isn't periodic enough to report a pitch.
    private static let confidenceThreshold = 0.8

    /// Returns the fundamental frequency in Hz, or nil if no clear pitch is found.
    public static func fundamentalFrequency(samples: [Int16], sampleRate: Double) -> Double? {
        guard let peak = samples.lazy.map({ abs(Int($0)) }).max(), peak > 0 else { return nil }
        let threshold = peak / 8
        guard let start = samples.firstIndex(where: { abs(Int($0)) >= threshold }) else { return nil }

        let x = samples[start..<min(samples.count, start + windowLength)].map { Double($0) }
        let minLag = Int(sampleRate / maximumFrequency)
        let maxLag = min(Int(sampleRate / minimumFrequency), x.count / 2)
        guard minLag >= 2, maxLag - minLag >= 3 else { return nil }

        var correlation = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            correlation[lag] = normalizedCorrelation(x, lag: lag)
        }

        let best = (minLag...maxLag).map { correlation[$0] }.max() ?? 0
        guard best >= confidenceThreshold else { return nil }

        // Smallest lag that is a strict local peak near the best correlation is the fundamental period.
        for lag in minLag...maxLag {
            let value = correlation[lag]
            guard value >= relativeThreshold * best,
                  value > correlation[lag - 1], value > correlation[lag + 1] else { continue }
            return sampleRate / refined(lag: lag, correlation: correlation)
        }
        return nil
    }

    private static func normalizedCorrelation(_ x: [Double], lag: Int) -> Double {
        var dot = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for i in 0..<(x.count - lag) {
            let a = x[i]
            let b = x[i + lag]
            dot += a * b
            energyA += a * a
            energyB += b * b
        }
        let denominator = (energyA * energyB).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    /// Parabolic interpolation around the peak, so non-integer periods don't snap to whole samples.
    private static func refined(lag: Int, correlation: [Double]) -> Double {
        let left = correlation[lag - 1]
        let center = correlation[lag]
        let right = correlation[lag + 1]
        let curvature = left - 2 * center + right
        guard curvature != 0 else { return Double(lag) }
        return Double(lag) + 0.5 * (left - right) / curvature
    }
}
