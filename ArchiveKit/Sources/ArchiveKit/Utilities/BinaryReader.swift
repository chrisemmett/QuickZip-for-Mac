import Foundation

/// A little-endian cursor over a byte buffer.
///
/// Every read is bounds-checked: running past the end throws rather than
/// trapping, because all archive bytes are untrusted (HLD §13).
struct BinaryReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int { bytes.count }
    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw ArchiveError.malformed("offset \(newOffset) is outside a \(bytes.count)-byte structure")
        }
        offset = newOffset
    }

    mutating func skip(_ length: Int) throws {
        try seek(to: try end(of: length))
    }

    mutating func readUInt8() throws -> UInt8 {
        let end = try end(of: 1)
        defer { offset = end }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let end = try end(of: 2)
        defer { offset = end }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let end = try end(of: 4)
        defer { offset = end }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let end = try end(of: 8)
        defer { offset = end }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    mutating func readBytes(_ length: Int) throws -> [UInt8] {
        let end = try end(of: length)
        defer { offset = end }
        return Array(bytes[offset..<end])
    }

    private func end(of length: Int) throws -> Int {
        guard length >= 0, length <= remaining else {
            throw ArchiveError.malformed("structure ends unexpectedly")
        }
        return offset + length
    }
}
