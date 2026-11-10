import XCTest
@testable import BRRCore

final class SampleReplacementTests: XCTestCase {
    func testChainEndsAtFirstEndBlock() {
        var ram = [UInt8](repeating: 0xAA, count: 0x100)
        ram[0x20] = 0x00
        ram[0x20 + 9] = 0x01
        XCTAssertEqual(SampleReplacement.chainBlockCount(in: ram, start: 0x20), 2)
    }

    func testChainWithoutEndIsNil() {
        let ram = [UInt8](repeating: 0x00, count: 0x40)
        XCTAssertNil(SampleReplacement.chainBlockCount(in: ram, start: 0x00))
    }

    func testLoopBlockMapsAlignedAddresses() {
        XCTAssertEqual(SampleReplacement.loopBlock(start: 0x1000, loopAddress: 0x1000 + 18, blockCount: 4), 2)
        XCTAssertNil(SampleReplacement.loopBlock(start: 0x1000, loopAddress: 0x1000 + 4, blockCount: 4))
        XCTAssertNil(SampleReplacement.loopBlock(start: 0x1000, loopAddress: 0x0FF0, blockCount: 4))
        XCTAssertNil(SampleReplacement.loopBlock(start: 0x1000, loopAddress: 0x1000 + 9 * 4, blockCount: 4))
    }

    func testMatchOriginalPlaysAtOriginalRoot() {
        // 880 Hz content declared at half its real rate plays at 440 Hz when the native rate is 32 kHz.
        let rate = SampleReplacement.declaredSourceRate(
            actualRate: 44_100, newFrequency: 880, originalFrequency: 440, mode: .matchOriginal, cents: 0
        )
        XCTAssertEqual(rate, 22_050, accuracy: 0.001)
        XCTAssertEqual(880 * rate / 44_100, 440, accuracy: 0.001)
    }

    func testKeepOwnKeepsOwnPitchAndAppliesCents() {
        let plain = SampleReplacement.declaredSourceRate(
            actualRate: 44_100, newFrequency: 880, originalFrequency: 440, mode: .keepOwn, cents: 0
        )
        XCTAssertEqual(plain, 44_100, accuracy: 0.001)

        let octaveUp = SampleReplacement.declaredSourceRate(
            actualRate: 44_100, newFrequency: 880, originalFrequency: 440, mode: .keepOwn, cents: 1200
        )
        XCTAssertEqual(octaveUp, 88_200, accuracy: 0.001)
    }

    func testUnpitchedSampleOnlyGetsFineTuning() {
        let rate = SampleReplacement.declaredSourceRate(
            actualRate: 32_000, newFrequency: nil, originalFrequency: 440, mode: .matchOriginal, cents: 1200
        )
        XCTAssertEqual(rate, 64_000, accuracy: 0.001)
    }
}
