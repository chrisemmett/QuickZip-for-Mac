import Foundation

/// Incremental CRC-32 (ISO 3309 / ITU-T V.42, as used by ZIP).
struct CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        state = c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = CRC32()
        bytes.withUnsafeBytes { crc.update($0) }
        return crc.value
    }
}
