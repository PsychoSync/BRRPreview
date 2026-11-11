import XCTest
@testable import BRRCore

final class InstrumentClassifierTests: XCTestCase {
    private let rate = BRRDecoder.sampleRate

    private func signal(count: Int, amplitude: Double = 12_000, _ value: (Double) -> Double) -> [Int16] {
        (0..<count).map { i in
            Int16(max(-32_767, min(32_767, amplitude * value(Double(i) / rate))))
        }
    }

    private func sine(_ frequency: Double, t: Double) -> Double {
        sin(2 * .pi * frequency * t)
    }

    /// Deterministic white noise so the tests don't depend on the system random generator.
    private func whiteNoise(count: Int) -> [Double] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    func testNoiseBurstWithFastDecayIsDrum() throws {
        let noise = whiteNoise(count: Int(rate * 0.5))
        let samples = noise.enumerated().map { i, v in
            Int16(12_000 * v * exp(-Double(i) / rate / 0.04))
        }
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: samples, sampleRate: rate, pitchHz: nil, hasLoop: false))
        XCTAssertEqual(guess.instrument, .drum)
        XCTAssertLessThan(guess.features.attackMs, 10)
        XCTAssertGreaterThan(guess.features.flatness, 0.35)
    }

    func testDecayingToneIsPluck() throws {
        let samples = signal(count: Int(rate), { t in sine(440, t: t) * exp(-t / 0.25) })
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: samples, sampleRate: rate, pitchHz: 440, hasLoop: false))
        XCTAssertEqual(guess.instrument, .pluck)
        XCTAssertEqual(guess.features.pitchHz, 440)
    }

    func testLoopedLowToneIsBass() throws {
        let samples = signal(count: Int(rate), { t in sine(110, t: t) })
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: samples, sampleRate: rate, pitchHz: 110, hasLoop: true))
        XCTAssertEqual(guess.instrument, .bass)
        XCTAssertTrue(guess.features.hasLoop)
    }

    func testSustainedHarmonicToneIsLead() throws {
        let samples = signal(count: Int(rate), amplitude: 8_000, { t in
            (1...10).reduce(0.0) { sum, k in sum + sine(880 * Double(k) / 1, t: t) / Double(k) }
        })
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: samples, sampleRate: rate, pitchHz: 880, hasLoop: false))
        XCTAssertEqual(guess.instrument, .lead)
        XCTAssertGreaterThan(guess.features.centroidHz, 1000)
    }

    func testSlowSwellingLoopedToneIsPad() throws {
        let samples = signal(count: Int(rate), { t in sine(330, t: t) * min(1, t / 0.3) })
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: samples, sampleRate: rate, pitchHz: 330, hasLoop: true))
        XCTAssertEqual(guess.instrument, .pad)
        XCTAssertGreaterThan(guess.features.attackMs, 60)
    }

    func testSilenceHasNoGuess() {
        XCTAssertNil(InstrumentClassifier.guess(samples: [Int16](repeating: 0, count: 4096), sampleRate: rate, pitchHz: nil, hasLoop: false))
    }

    func testEmptyInputHasNoGuess() {
        XCTAssertNil(InstrumentClassifier.guess(samples: [], sampleRate: rate, pitchHz: nil, hasLoop: false))
    }

    func testVeryShortSampleDoesNotCrash() throws {
        let guess = try XCTUnwrap(InstrumentClassifier.guess(samples: [1_000, 2_000, 1_500], sampleRate: rate, pitchHz: nil, hasLoop: false))
        XCTAssertTrue((0...1).contains(guess.confidence))
        XCTAssertFalse(guess.reasons.isEmpty)
    }
}
