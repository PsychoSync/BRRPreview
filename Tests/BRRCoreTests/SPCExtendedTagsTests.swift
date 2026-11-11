import XCTest
@testable import BRRCore

final class SPCExtendedTagsTests: XCTestCase {
    private func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    /// A block with a string, an inline item, an integer, and an unknown padded item.
    private func canonicalBlock() -> [UInt8] {
        var body: [UInt8] = []
        body += [0x01, 0x01, 5, 0] + Array("Song".utf8) + [0, 0, 0, 0]
        body += [0x11, 0x00, 0x01, 0x00]
        body += [0x05, 0x04, 4, 0] + le32(20_240_101)
        body += [0x40, 0x02, 5, 0] + [1, 2, 3, 4, 5] + [0, 0, 0]
        return Array("xid6".utf8) + le32(body.count) + body
    }

    func testMissingBlockYieldsNothing() {
        XCTAssertTrue(SPCExtendedTags(tail: []).items.isEmpty)
        XCTAssertTrue(SPCExtendedTags(tail: Array("junk after the image".utf8)).items.isEmpty)
        XCTAssertTrue(SPCExtendedTags().serialized().isEmpty)
    }

    func testParsesEveryItemKind() {
        let tags = SPCExtendedTags(tail: canonicalBlock())
        XCTAssertEqual(tags.items.count, 4)
        XCTAssertEqual(tags.text(0x01), "Song")
        XCTAssertEqual(tags.integer(0x05), 20_240_101)
        XCTAssertEqual(tags.items[1].bytes, [0x01, 0x00])
        XCTAssertEqual(tags.items[3].bytes, [1, 2, 3, 4, 5])
        XCTAssertTrue(tags.remainder.isEmpty)
    }

    func testCanonicalBlockRoundTripsByteForByte() {
        let raw = canonicalBlock()
        XCTAssertEqual(SPCExtendedTags(tail: raw).serialized(), raw)
    }

    func testEditingChangesOnlyTheEditedItem() {
        var tags = SPCExtendedTags(tail: canonicalBlock())
        let unknown = tags.items[3]

        tags.setText(0x01, "Renamed")
        XCTAssertEqual(tags.text(0x01), "Renamed")
        XCTAssertEqual(tags.items.count, 4)
        XCTAssertEqual(tags.items[3], unknown)

        let reparsed = SPCExtendedTags(tail: tags.serialized())
        XCTAssertEqual(reparsed.text(0x01), "Renamed")
        XCTAssertEqual(reparsed.integer(0x05), 20_240_101)
        XCTAssertEqual(reparsed.items[1].bytes, [0x01, 0x00])
    }

    func testEmptyValueRemovesItem() {
        var tags = SPCExtendedTags(tail: canonicalBlock())
        tags.setText(0x01, "")
        XCTAssertNil(tags.text(0x01))
        tags.setInteger(0x05, nil)
        XCTAssertNil(tags.integer(0x05))
        XCTAssertEqual(tags.items.count, 2)
    }

    func testAddingItemAppendsAndRoundTrips() {
        var tags = SPCExtendedTags()
        tags.setText(0x02, "Game")
        tags.setInteger(0x05, -1)
        XCTAssertEqual(tags.integer(0x05), -1)

        let reparsed = SPCExtendedTags(tail: tags.serialized())
        XCTAssertEqual(reparsed.text(0x02), "Game")
        XCTAssertEqual(reparsed.integer(0x05), -1)
    }

    func testMalformedLengthIsKeptAsRemainder() {
        let body: [UInt8] = [0x01, 0x01, 0xFF, 0x00, 1, 2]
        let raw = Array("xid6".utf8) + le32(body.count) + body
        let tags = SPCExtendedTags(tail: raw)
        XCTAssertTrue(tags.items.isEmpty)
        XCTAssertEqual(tags.remainder, body)
        XCTAssertEqual(tags.serialized(), raw)
    }
}
