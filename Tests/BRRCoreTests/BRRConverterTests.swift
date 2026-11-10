import XCTest
@testable import BRRCore

final class BRRConverterTests: XCTestCase {
    private func tone(rate: Double, count: Int) -> [Float] {
        (0..<count).map { (i: Int) -> Float in
            let phase: Double = 2 * Double.pi * 440 * Double(i) / rate
            return 0.5 * Float(sin(phase))
        }
    }

    func testPitchRegisterMatchesOutputRate() {
        XCTAssertEqual(BRRConverter.pitchRegister(for: 32_000), 0x1000)
        XCTAssertEqual(BRRConverter.pitchRegister(for: 16_000), 2048)
        XCTAssertEqual(BRRConverter.pitchRegister(for: 8_000), 1024)
    }

    func testConvertAtThirtyTwoKilohertzKeepsLengthAndRate() {
        let sample = EditableSample(samples: tone(rate: 32_000, count: 1_600), sourceRate: 32_000)
        let conversion = BRRConverter.convert(sample, outputRate: 32_000)
        XCTAssertEqual(conversion.sampleCount, 1_600)
        XCTAssertEqual(conversion.pitchRegister, 0x1000)
    }

    func testConvertDownsamplesAndMapsLoopToOutputRate() {
        // 48 kHz source, loop at source sample 4800 (0.1 s) becomes output sample 1600 at 16 kHz.
        let sample = EditableSample(samples: tone(rate: 48_000, count: 9_600), sourceRate: 48_000, loopStart: 4_800)
        let conversion = BRRConverter.convert(sample, outputRate: 16_000)
        XCTAssertEqual(conversion.encoding.loopStart, 1_600)
        XCTAssertEqual(conversion.pitchRegister, 2_048)

        let decoded = BRRDecoder.decodeFile(conversion.file)
        XCTAssertEqual(decoded.loopStart, 1_600)
        XCTAssertEqual(decoded.samples.count, conversion.sampleCount)
    }

    func testConvertWithoutLoopWritesSentinel() {
        let sample = EditableSample(samples: tone(rate: 32_000, count: 320), sourceRate: 32_000)
        let conversion = BRRConverter.convert(sample, outputRate: 32_000)
        XCTAssertNil(BRRDecoder.decodeFile(conversion.file).loopStart)
    }
}
