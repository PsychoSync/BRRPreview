import XCTest
@testable import BRRCore

final class ResamplerTests: XCTestCase {
    private func sine(frequency: Double, rate: Double, count: Int) -> [Float] {
        (0..<count).map { (i: Int) -> Float in
            let phase: Double = 2 * Double.pi * frequency * Double(i) / rate
            return Float(sin(phase))
        }
    }

    /// RMS over the middle of the signal, away from the edges.
    private func rms(_ samples: [Float]) -> Double {
        let middle = samples.dropFirst(samples.count / 4).dropLast(samples.count / 4)
        let energy = middle.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(middle.count)).squareRoot()
    }

    func testSameRateReturnsInputUnchanged() {
        let input = sine(frequency: 440, rate: 32_000, count: 100)
        XCTAssertEqual(Resampler.resample(input, from: 32_000, to: 32_000), input)
    }

    func testOutputLengthScalesWithRate() {
        let input = [Float](repeating: 0.1, count: 4_800)
        XCTAssertEqual(Resampler.resample(input, from: 48_000, to: 16_000).count, 1_600)
        XCTAssertEqual(Resampler.resample(input, from: 48_000, to: 32_000).count, 3_200)
    }

    func testLowToneSurvivesDownsampling() {
        let input = sine(frequency: 1_000, rate: 48_000, count: 9_600)
        let output = Resampler.resample(input, from: 48_000, to: 32_000)
        // Expect the same tone at the new rate: unit sine has RMS 1/sqrt(2).
        XCTAssertEqual(rms(output), 1 / 2.0.squareRoot(), accuracy: 0.02)
    }

    func testToneAboveNewNyquistIsRejected() {
        // 12 kHz is above the 8 kHz Nyquist of a 16 kHz output and should be removed.
        let input = sine(frequency: 12_000, rate: 48_000, count: 9_600)
        let output = Resampler.resample(input, from: 48_000, to: 16_000)
        XCTAssertLessThan(rms(output), 0.02)
    }

    func testUpsamplingPreservesTone() {
        let input = sine(frequency: 1_000, rate: 16_000, count: 1_600)
        let output = Resampler.resample(input, from: 16_000, to: 32_000)
        XCTAssertEqual(rms(output), 1 / 2.0.squareRoot(), accuracy: 0.02)
    }
}
