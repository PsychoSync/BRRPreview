import Foundation

private let fftLength = 1024
private let spectrumWindowCount = 8

private enum Tables {
    static let window: [Double] = (0..<fftLength).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftLength)) }
    static let cosine: [Double] = (0..<fftLength).map { cos(2 * Double.pi * Double($0) / Double(fftLength)) }
}

public enum InstrumentClass: String, CaseIterable, Sendable {
    case drum, pluck, bass, lead, pad, noise, unknown

    public var displayName: String {
        switch self {
        case .drum: return "Drum / percussion"
        case .pluck: return "Pluck / mallet / bell"
        case .bass: return "Bass"
        case .lead: return "Lead / brass / synth"
        case .pad: return "Pad / strings"
        case .noise: return "Noise / FX"
        case .unknown: return "Unknown"
        }
    }
}

public struct SampleFeatures: Equatable, Sendable {
    public var durationMs: Double
    /// Time from the start of the sound to 90% of its peak level.
    public var attackMs: Double
    /// Time from 90% of the peak to 20 dB below it, or to the end of the sample if it never gets that quiet.
    public var decayMs: Double
    /// Level over the last quarter of the sample, relative to the peak (0...1).
    public var tailLevel: Double
    /// Power-weighted mean spectral centroid in Hz.
    public var centroidHz: Double
    /// Spectral flatness from 0 (pure tone) to 1 (white noise).
    public var flatness: Double
    public var pitchHz: Double?
    public var hasLoop: Bool
}

public struct InstrumentGuess: Equatable, Sendable {
    public var instrument: InstrumentClass
    /// Score of the winning class, from 0 to 1.
    public var confidence: Double
    public var features: SampleFeatures
    /// Plain-language notes on the measurements behind the guess.
    public var reasons: [String]
}

/// Heuristic guess at the instrument family from a sample's envelope and spectrum.
/// It is not a trained model, so it can be wrong, especially for short or heavily processed samples.
public enum InstrumentClassifier {
    private static let envelopeWindowMs = 5.0
    private static let sustainedTailLevel = 0.35
    private static let tonalFlatness = 0.2
    private static let noisyFlatness = 0.35
    private static let minimumScore = 0.4

    public static func guess(samples: [Int16], sampleRate: Double, pitchHz: Double?, hasLoop: Bool) -> InstrumentGuess? {
        guard let features = features(samples: samples, sampleRate: sampleRate, pitchHz: pitchHz, hasLoop: hasLoop) else {
            return nil
        }
        let scores = scores(for: features)
        guard let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        let instrument = best.score >= minimumScore ? best.instrument : .unknown
        return InstrumentGuess(instrument: instrument, confidence: best.score, features: features,
                               reasons: reasons(for: features))
    }

    public static func features(samples: [Int16], sampleRate: Double, pitchHz: Double?, hasLoop: Bool) -> SampleFeatures? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let x = samples.map { Double($0) / 32_768 }
        let envelope = rmsEnvelope(x, windowSamples: max(1, Int(sampleRate * envelopeWindowMs / 1000)))
        guard let peak = envelope.max(), peak > 0 else { return nil }

        let onset = envelope.firstIndex(where: { $0 >= 0.1 * peak }) ?? 0
        let reach = envelope.firstIndex(where: { $0 >= 0.9 * peak }) ?? onset
        let quiet = envelope[reach...].firstIndex(where: { $0 < 0.1 * peak }) ?? envelope.count
        let tail = envelope[(envelope.count * 3 / 4)...]
        let spectrum = spectralShape(x, sampleRate: sampleRate)

        return SampleFeatures(
            durationMs: Double(x.count) / sampleRate * 1000,
            attackMs: Double(reach - onset) * envelopeWindowMs,
            decayMs: Double(quiet - reach) * envelopeWindowMs,
            tailLevel: min(1, tail.reduce(0, +) / Double(tail.count) / peak),
            centroidHz: spectrum.centroid,
            flatness: spectrum.flatness,
            pitchHz: pitchHz,
            hasLoop: hasLoop
        )
    }

    private static func scores(for f: SampleFeatures) -> [(instrument: InstrumentClass, score: Double)] {
        let fast = f.attackMs <= 10
        let quickish = f.attackMs <= 60
        let slow = f.attackMs >= 60
        let short = f.decayMs <= 400
        let sustained = f.hasLoop || f.tailLevel >= sustainedTailLevel
        let tonal = f.flatness < tonalFlatness
        let noisy = f.flatness > noisyFlatness
        let lowPitched = f.pitchHz.map { $0 < 220 } ?? (f.centroidHz < 500)
        let bright = f.centroidHz > 1000

        return [
            (.drum, weightedScore([(fast, 2), (short, 1), (!sustained, 1), (noisy, 1)])),
            (.pluck, weightedScore([(f.attackMs <= 15, 1), ((150...2500).contains(f.decayMs), 1), (!sustained, 1), (tonal, 2)])),
            (.bass, weightedScore([(lowPitched, 2), (tonal, 1), (sustained, 1), (quickish, 1)])),
            (.lead, weightedScore([(bright, 2), (sustained, 1), (tonal, 1), (quickish, 1)])),
            (.pad, weightedScore([(slow, 2), (sustained, 2), (!noisy, 1)])),
            (.noise, weightedScore([(noisy, 2), (sustained, 1), (f.decayMs >= 400, 1), (f.centroidHz > 2000, 1)])),
        ]
    }

    private static func weightedScore(_ terms: [(Bool, Double)]) -> Double {
        let total = terms.reduce(0) { $0 + $1.1 }
        return terms.reduce(0) { $0 + ($1.0 ? $1.1 : 0) } / total
    }

    private static func reasons(for f: SampleFeatures) -> [String] {
        var lines = [
            String(format: "Attack %.0f ms", f.attackMs),
            String(format: "Decay %.0f ms", f.decayMs),
        ]
        if f.hasLoop {
            lines.append("Loops")
        } else {
            lines.append(f.tailLevel >= sustainedTailLevel ? "Sustains to the end" : "Dies away")
        }
        lines.append(String(format: "Centroid %.0f Hz", f.centroidHz))
        if f.flatness > noisyFlatness {
            lines.append("Noisy spectrum")
        } else if f.flatness < tonalFlatness {
            lines.append("Tonal spectrum")
        } else {
            lines.append("Mixed spectrum")
        }
        if let pitch = f.pitchHz {
            lines.append(String(format: "Pitch %.1f Hz", pitch))
        }
        return lines
    }

    private static func rmsEnvelope(_ x: [Double], windowSamples: Int) -> [Double] {
        stride(from: 0, to: x.count, by: windowSamples).map { start in
            let end = min(x.count, start + windowSamples)
            var sum = 0.0
            for i in start..<end { sum += x[i] * x[i] }
            return (sum / Double(end - start)).squareRoot()
        }
    }

    /// Averages the spectral centroid and flatness over evenly spaced Hann-windowed frames,
    /// weighting each frame by its energy so quiet tail frames barely count.
    private static func spectralShape(_ x: [Double], sampleRate: Double) -> (centroid: Double, flatness: Double) {
        let n = fftLength
        let half = n / 2
        let binHz = sampleRate / Double(n)
        let starts: [Int] = x.count <= n
            ? [0]
            : (0..<spectrumWindowCount).map { $0 * (x.count - n) / (spectrumWindowCount - 1) }

        var weightSum = 0.0
        var centroidSum = 0.0
        var flatnessSum = 0.0
        var frame = [Double](repeating: 0, count: n)
        var power = [Double](repeating: 0, count: half)
        for start in starts {
            let length = min(n, x.count - start)
            for i in 0..<n {
                frame[i] = i < length ? x[start + i] * Tables.window[i] : 0
            }
            for k in 1..<half {
                var re = 0.0
                var im = 0.0
                for i in 0..<n {
                    let m = (k * i) & (n - 1)
                    re += frame[i] * Tables.cosine[m]
                    im -= frame[i] * Tables.cosine[(m - n / 4) & (n - 1)]
                }
                power[k] = re * re + im * im
            }

            let total = power[1..<half].reduce(0, +)
            guard total > 0 else { continue }
            var weighted = 0.0
            for k in 1..<half {
                weighted += Double(k) * binHz * power[k]
            }
            let epsilon = total / Double(half) * 1e-6
            let logMean = power[1..<half].reduce(0) { $0 + log($1 + epsilon) } / Double(half - 1)
            let flatness = exp(logMean) / (total / Double(half - 1))
            weightSum += total
            centroidSum += weighted
            flatnessSum += flatness * total
        }
        guard weightSum > 0 else { return (0, 0) }
        return (centroidSum / weightSum, flatnessSum / weightSum)
    }
}
