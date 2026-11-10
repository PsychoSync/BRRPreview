import XCTest
@testable import BRRCore

final class BRRDecoderTests: XCTestCase {
    private func block(_ header: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        [header] + payload + [UInt8](repeating: 0, count: 8 - payload.count)
    }

    func testEmptyInputDecodesToNothing() {
        let result = BRRDecoder.decode([])
        XCTAssertEqual(result.samples, [])
        XCTAssertEqual(result.blockCount, 0)
        XCTAssertFalse(result.hasEndFlag)
    }

    func testSilenceDecodesToZeros() {
        let result = BRRDecoder.decode(block(0x00))
        XCTAssertEqual(result.samples, [Int16](repeating: 0, count: 16))
        XCTAssertEqual(result.blockCount, 1)
    }

    func testRangeShiftsNibbleAndHalves() {
        // Range 4: nibble 1 -> 8, nibble 2 -> 16, nibble -1 (0xF) -> -8.
        let result = BRRDecoder.decode(block(0x40, [0x12, 0xF0]))
        XCTAssertEqual(Array(result.samples.prefix(4)), [8, 16, -8, 0])
    }

    func testInvalidRangeCollapsesToSignOnly() {
        // Range 13: -8 -> -2048, and a non-negative nibble -> 0.
        let result = BRRDecoder.decode(block(0xD0, [0x80, 0x70]))
        XCTAssertEqual(Array(result.samples.prefix(3)), [-2048, 0, 0])
    }

    func testFilter1UsesPreviousSample() {
        // Range 12, filter 1: 2048, then 15/16 * 2048 = 1920.
        let result = BRRDecoder.decode(block(0xC4, [0x10]))
        XCTAssertEqual(Array(result.samples.prefix(2)), [2048, 1920])
    }

    func testFilter2UsesTwoPreviousSamples() {
        // Range 12, filter 2: 61/32 * 2048 = 3904.
        let result = BRRDecoder.decode(block(0xC8, [0x10]))
        XCTAssertEqual(Array(result.samples.prefix(2)), [2048, 3904])
    }

    func testFilter3UsesTwoPreviousSamples() {
        // Range 12, filter 3: 115/64 * 2048 = 3680.
        let result = BRRDecoder.decode(block(0xCC, [0x10]))
        XCTAssertEqual(Array(result.samples.prefix(2)), [2048, 3680])
    }

    func testOutputSaturatesToSixteenBits() {
        // Range 12, filter 1, all-positive nibbles: 14336, 27776, then clipped to 32767.
        let result = BRRDecoder.decode(block(0xC4, [0x77, 0x77]))
        XCTAssertEqual(Array(result.samples.prefix(3)), [14336, 27776, 32767])
    }

    func testEndFlagStopsDecodingAndReportsLoop() {
        let bytes = block(0x03, [0x10]) + block(0x00, [0x10])
        let result = BRRDecoder.decode(bytes)
        XCTAssertEqual(result.samples.count, 16)
        XCTAssertEqual(result.blockCount, 1)
        XCTAssertTrue(result.hasEndFlag)
        XCTAssertTrue(result.hasLoopFlag)
    }

    func testMissingEndFlagDecodesWholeFile() {
        let bytes = block(0x00) + block(0x00)
        let result = BRRDecoder.decode(bytes)
        XCTAssertEqual(result.samples.count, 32)
        XCTAssertEqual(result.blockCount, 2)
        XCTAssertFalse(result.hasEndFlag)
        XCTAssertFalse(result.hasLoopFlag)
    }

    func testTrailingPartialBlockIsIgnored() {
        let result = BRRDecoder.decode(block(0x00) + [0x00, 0x00])
        XCTAssertEqual(result.samples.count, 16)
        XCTAssertEqual(result.blockCount, 1)
    }

    func testFileWithoutLoopPrefixDecodesFromStart() {
        let result = BRRDecoder.decodeFile(block(0x03, [0x10]))
        XCTAssertEqual(result.samples.count, 16)
        XCTAssertNil(result.loopStart)
    }

    func testLoopPrefixIsSkippedAndLoopStartIsReported() {
        // Size 2 mod 9: a 2-byte little-endian loop offset of 9 (one block), then two blocks.
        let bytes: [UInt8] = [0x09, 0x00] + block(0x00, [0x10]) + block(0x03, [0x10])
        let result = BRRDecoder.decodeFile(bytes)
        XCTAssertEqual(result.samples.count, 32)
        XCTAssertEqual(result.loopStart, 16)
        XCTAssertEqual(result.blockCount, 2)
        XCTAssertTrue(result.hasEndFlag)
    }

    func testLoopPrefixNotOnBlockBoundaryIsIgnored() {
        let bytes: [UInt8] = [0x05, 0x00] + block(0x03, [0x10])
        XCTAssertNil(BRRDecoder.decodeFile(bytes).loopStart)
    }
}
