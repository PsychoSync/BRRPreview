import XCTest
@testable import BRRCore

final class PianoKeysTests: XCTestCase {
    func testWhiteKeysFollowTheOctave() {
        let expected: [(Character, Int)] = [("q", 0), ("w", 2), ("e", 4), ("r", 5), ("t", 7), ("y", 9), ("u", 11), ("i", 12), ("o", 14), ("p", 16)]
        for (key, offset) in expected {
            XCTAssertEqual(PianoKeys.midi(for: key, octaveBase: 60), 60 + offset, "key \(key)")
        }
    }

    func testBlackKeysSitBetweenWhiteKeys() {
        let expected: [(Character, Int)] = [("2", 1), ("3", 3), ("5", 6), ("6", 8), ("7", 10), ("9", 13), ("0", 15)]
        for (key, offset) in expected {
            XCTAssertEqual(PianoKeys.midi(for: key, octaveBase: 60), 60 + offset, "key \(key)")
        }
    }

    func testUppercaseLettersMatchLowercase() {
        XCTAssertEqual(PianoKeys.midi(for: "Q", octaveBase: 48), 48)
    }

    func testNonPianoKeysReturnNil() {
        XCTAssertNil(PianoKeys.midi(for: "a", octaveBase: 60))
        XCTAssertNil(PianoKeys.midi(for: "1", octaveBase: 60))
        XCTAssertNil(PianoKeys.midi(for: " ", octaveBase: 60))
    }
}
