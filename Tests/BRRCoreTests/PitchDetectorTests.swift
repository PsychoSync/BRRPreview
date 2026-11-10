import XCTest
@testable import BRRCore

final class PitchDetectorTests: XCTestCase {
    private func sine(frequency: Double, count: Int = 8192, amplitude: Double = 10_000) -> [Int16] {
        (0..<count).map { i in
            Int16(amplitude * sin(2 * .pi * frequency * Double(i) / BRRDecoder.sampleRate))
        }
    }

    func testDetectsSineFrequency() throws {
        let detected = try XCTUnwrap(PitchDetector.fundamentalFrequency(samples: sine(frequency: 440), sampleRate: BRRDecoder.sampleRate))
        XCTAssertEqual(detected, 440, accuracy: 440 * 0.005)
    }

    func testDetectsMiddleCNearItsFrequency() throws {
        let detected = try XCTUnwrap(PitchDetector.fundamentalFrequency(samples: sine(frequency: 261.63), sampleRate: BRRDecoder.sampleRate))
        XCTAssertEqual(Int(Note.midi(frequency: detected).rounded()), 60)
    }

    /// Encodes a sine as BRR blocks (range 12, filter 0) so the pitch check runs on real decoder output.
    private func brrSine(frequency: Double, blocks: Int) -> [UInt8] {
        let nibbles = (0..<(blocks * 16)).map { i in
            Int((7 * sin(2 * .pi * frequency * Double(i) / BRRDecoder.sampleRate)).rounded())
        }
        var bytes: [UInt8] = []
        for block in 0..<blocks {
            bytes.append(0xC0)
            for pair in 0..<8 {
                let high = nibbles[block * 16 + pair * 2] & 0xF
                let low = nibbles[block * 16 + pair * 2 + 1] & 0xF
                bytes.append(UInt8(high << 4 | low))
            }
        }
        return bytes
    }

    func testDetectsPitchOfDecodedBRR() throws {
        let decoded = BRRDecoder.decode(brrSine(frequency: 880, blocks: 256))
        let detected = try XCTUnwrap(PitchDetector.fundamentalFrequency(samples: decoded.samples, sampleRate: BRRDecoder.sampleRate))
        XCTAssertEqual(detected, 880, accuracy: 880 * 0.01)
    }

    func testSilenceHasNoPitch() {
        XCTAssertNil(PitchDetector.fundamentalFrequency(samples: [Int16](repeating: 0, count: 4096), sampleRate: BRRDecoder.sampleRate))
    }

    func testConstantSignalHasNoPitch() {
        XCTAssertNil(PitchDetector.fundamentalFrequency(samples: [Int16](repeating: 5000, count: 4096), sampleRate: BRRDecoder.sampleRate))
    }

    func testNoiseHasNoPitch() {
        var state: UInt32 = 12345
        let noise: [Int16] = (0..<4096).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return Int16(truncatingIfNeeded: Int32(state >> 16) - 32768)
        }
        XCTAssertNil(PitchDetector.fundamentalFrequency(samples: noise, sampleRate: BRRDecoder.sampleRate))
    }
}

final class NoteTests: XCTestCase {
    func testMiddleCFrequency() {
        XCTAssertEqual(Note.frequency(midi: 60), 261.6256, accuracy: 0.001)
    }

    func testA440RoundTrip() {
        XCTAssertEqual(Note.midi(frequency: 440), 69, accuracy: 1e-9)
    }

    func testNames() {
        XCTAssertEqual(Note.name(midi: 60), "C4")
        XCTAssertEqual(Note.name(midi: 69), "A4")
        XCTAssertEqual(Note.name(midi: 61), "C#4")
        XCTAssertEqual(Note.name(midi: 0), "C-1")
    }

    func testParsesNoteAtEndOfName() {
        XCTAssertEqual(Note.midi(parsing: "Eighty Pad C5"), 72)
        XCTAssertEqual(Note.midi(parsing: "Choir Halo C2"), 36)
        XCTAssertEqual(Note.midi(parsing: "C4"), 60)
    }

    func testParsesAccidentals() {
        XCTAssertEqual(Note.midi(parsing: "Pad F#3"), 54)
        XCTAssertEqual(Note.midi(parsing: "Pad Bb2"), 46)
    }

    func testIgnoresNamesWithoutTrailingNote() {
        XCTAssertNil(Note.midi(parsing: "Fifth Ensemble 80"))
        XCTAssertNil(Note.midi(parsing: "Dreamcast"))
        XCTAssertNil(Note.midi(parsing: "Pad C5 Mix"))
        XCTAssertNil(Note.midi(parsing: "PadC5"))
    }
}
