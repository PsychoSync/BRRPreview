import XCTest
@testable import BRRCore

final class BRREncoderTests: XCTestCase {
    private func sine(frequency: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { (i: Int) -> Float in
            let phase: Double = 2 * Double.pi * frequency * Double(i) / BRRDecoder.sampleRate
            return amplitude * Float(sin(phase))
        }
    }

    private func decodedSNR(_ input: [Float], _ decoded: [Int16]) -> Double {
        var signal = 0.0
        var noise = 0.0
        for i in input.indices {
            let x = Double(input[i]) * 32768
            let e = x - Double(decoded[i])
            signal += x * x
            noise += e * e
        }
        return 10 * log10(signal / max(noise, 1e-9))
    }

    func testRoundTripOfSineIsAccurate() {
        let input = sine(frequency: 440, count: 1600)
        let encoding = BRREncoder.encode(input)
        let decoded = BRRDecoder.decode(encoding.data).samples
        XCTAssertEqual(decoded.count, input.count)
        XCTAssertGreaterThan(decodedSNR(input, decoded), 25)
    }

    func testEncodingProducesOneBlockPerSixteenSamples() {
        let encoding = BRREncoder.encode(sine(frequency: 440, count: 33))
        XCTAssertEqual(encoding.blockCount, 3)
        XCTAssertEqual(encoding.data.count, 3 * BRRDecoder.blockSize)
    }

    func testOnlyLastBlockHasEndFlag() {
        let encoding = BRREncoder.encode(sine(frequency: 440, count: 64))
        for block in 0..<encoding.blockCount {
            let header = encoding.data[block * BRRDecoder.blockSize]
            XCTAssertEqual(header & 0x01 != 0, block == encoding.blockCount - 1)
            XCTAssertEqual(header & 0x02, 0)
        }
    }

    func testEmptyInputEncodesOneSilentBlock() {
        let encoding = BRREncoder.encode([])
        XCTAssertEqual(encoding.blockCount, 1)
        XCTAssertEqual(BRRDecoder.decode(encoding.data).samples, [Int16](repeating: 0, count: 16))
    }

    func testLoopIsRoundedToBlockAndMarkedOnEndBlock() {
        let encoding = BRREncoder.encode(sine(frequency: 440, count: 160), loopStart: 36)
        // 36 is closer to block 2 (sample 32) than to block 3 (sample 48).
        XCTAssertEqual(encoding.loopBlock, 2)
        XCTAssertEqual(encoding.loopStart, 32)
        let lastHeader = encoding.data[(encoding.blockCount - 1) * BRRDecoder.blockSize]
        XCTAssertEqual(lastHeader & 0x03, 0x03)
        let loopHeader = encoding.data[encoding.loopBlock! * BRRDecoder.blockSize]
        XCTAssertEqual((loopHeader >> 2) & 0x3, 0, "Loop block must use filter 0")
    }

    func testLoopBlockIsClampedToLastBlock() {
        let encoding = BRREncoder.encode(sine(frequency: 440, count: 32), loopStart: 1000)
        XCTAssertEqual(encoding.loopBlock, 1)
    }

    func testFileHeaderStoresLoopOffsetInBytes() {
        let encoding = BRREncoder.encode(sine(frequency: 440, count: 160), loopStart: 32)
        let bytes = BRREncoder.file(encoding)
        XCTAssertEqual(bytes.count, 2 + encoding.data.count)
        XCTAssertEqual(Int(bytes[0]) | Int(bytes[1]) << 8, 2 * BRRDecoder.blockSize)

        let result = BRRDecoder.decodeFile(bytes)
        XCTAssertEqual(result.loopStart, 32)
        XCTAssertEqual(result.samples, BRRDecoder.decode(encoding.data).samples)
    }

    func testFileWithoutLoopUsesSentinel() {
        let bytes = BRREncoder.file(BRREncoder.encode(sine(frequency: 440, count: 32)))
        XCTAssertEqual(Int(bytes[0]) | Int(bytes[1]) << 8, 0xFFFF)
        XCTAssertNil(BRRDecoder.decodeFile(bytes).loopStart)
    }

    func testLoopBeyondHeaderRangeIsReportedNotStored() {
        // The last block whose byte offset is at or above 0xFFFF cannot be stored.
        let blocks = 0xFFFF / BRRDecoder.blockSize + 2
        let encoding = BRREncoder.encode([Float](repeating: 0, count: blocks * 16), loopStart: (blocks - 1) * 16)
        XCTAssertFalse(encoding.loopHeaderFits)
        let bytes = BRREncoder.file(encoding)
        XCTAssertEqual(Int(bytes[0]) | Int(bytes[1]) << 8, 0xFFFF)
    }

    func testFullScaleSquareDoesNotOverflow() {
        let square = (0..<320).map { ($0 / 40) % 2 == 0 ? Float(1) : Float(-1) }
        let decoded = BRRDecoder.decode(BRREncoder.encode(square).data).samples
        XCTAssertEqual(decoded.count, square.count)
        XCTAssertTrue(decoded.allSatisfy { $0 >= -32768 && $0 <= 32767 })
    }
}
