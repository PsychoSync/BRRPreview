import Foundation

/// The extended ID666 block (`xid6`) stored after an SPC's 66,048-byte image.
///
/// Items stay in file order. Items the app doesn't edit are written back unchanged, and bytes that
/// don't parse are kept as `remainder`, so saving never drops data the user didn't touch.
public struct SPCExtendedTags: Equatable {
    public struct Item: Equatable {
        public let id: UInt8
        /// `0` keeps the value inline in the sub-chunk header. Any other type stores data after the header.
        public let type: UInt8
        /// Two inline bytes for type `0`, otherwise the data that follows the header.
        public var bytes: [UInt8]
    }

    public static let typeData: UInt8 = 0
    public static let typeString: UInt8 = 1
    public static let typeInteger: UInt8 = 4

    public private(set) var items: [Item]
    public private(set) var remainder: [UInt8]

    public init() {
        items = []
        remainder = []
    }

    /// Parses the bytes that follow the emulator image. Yields no items unless they start with `xid6`.
    public init(tail: [UInt8]) {
        items = []
        remainder = []
        guard tail.count >= 8, Array(tail[0..<4]) == Self.signature else { return }
        let size = min(Self.readLE(tail, at: 4, count: 4), tail.count - 8)
        let body = Array(tail[8..<(8 + size)])

        var pos = 0
        while pos + 4 <= body.count {
            let id = body[pos]
            let type = body[pos + 1]
            if type == Self.typeData {
                items.append(Item(id: id, type: type, bytes: Array(body[(pos + 2)..<(pos + 4)])))
                pos += 4
                continue
            }
            let length = Self.readLE(body, at: pos + 2, count: 2)
            guard pos + 4 + length <= body.count else { break }
            items.append(Item(id: id, type: type, bytes: Array(body[(pos + 4)..<(pos + 4 + length)])))
            pos += 4 + Self.paddedLength(length)
        }
        if pos < body.count {
            remainder = Array(body[pos...])
        }
    }

    /// The block to append after the image. Empty when there is nothing to store.
    public func serialized() -> [UInt8] {
        guard !items.isEmpty || !remainder.isEmpty else { return [] }
        var body: [UInt8] = []
        for item in items {
            body.append(item.id)
            body.append(item.type)
            if item.type == Self.typeData {
                body += (0..<2).map { $0 < item.bytes.count ? item.bytes[$0] : 0 }
            } else {
                body += Self.le(item.bytes.count, count: 2)
                body += item.bytes
                body += [UInt8](repeating: 0, count: Self.paddedLength(item.bytes.count) - item.bytes.count)
            }
        }
        body += remainder
        return Self.signature + Self.le(body.count, count: 4) + body
    }

    /// A string item's text, decoded as 8-bit Latin-1 without its terminating null.
    public func text(_ id: UInt8) -> String? {
        guard let item = items.first(where: { $0.id == id && $0.type == Self.typeString }) else { return nil }
        return String(bytes: item.bytes.prefix(while: { $0 != 0 }), encoding: .isoLatin1)
    }

    /// Sets a string item. An empty value removes it. Text is stored as 8-bit Latin-1 and capped at 255 bytes.
    public mutating func setText(_ id: UInt8, _ value: String) {
        let encoded = Array((value.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(255))
        guard !encoded.isEmpty else {
            remove(id)
            return
        }
        store(Item(id: id, type: Self.typeString, bytes: encoded + [0]))
    }

    public func integer(_ id: UInt8) -> Int? {
        guard let item = items.first(where: { $0.id == id && $0.type == Self.typeInteger }),
              item.bytes.count == 4 else { return nil }
        return Int(Int32(bitPattern: UInt32(Self.readLE(item.bytes, at: 0, count: 4))))
    }

    /// Sets a 32-bit integer item. A nil value removes it.
    public mutating func setInteger(_ id: UInt8, _ value: Int?) {
        guard let value else {
            remove(id)
            return
        }
        let bits = Int(UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        store(Item(id: id, type: Self.typeInteger, bytes: Self.le(bits, count: 4)))
    }

    private mutating func store(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private mutating func remove(_ id: UInt8) {
        items.removeAll { $0.id == id }
    }

    private static let signature: [UInt8] = Array("xid6".utf8)

    private static func paddedLength(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private static func readLE(_ bytes: [UInt8], at offset: Int, count: Int) -> Int {
        (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }

    private static func le(_ value: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
