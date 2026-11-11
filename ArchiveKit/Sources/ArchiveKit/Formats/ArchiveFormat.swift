import Foundation

/// The kind of archive a file is, found from its first bytes rather than
/// its name (HLD §18.4).
public enum ArchiveFormat: Equatable, Sendable {
    case zip
    case tar
    case tarGzip
    case tarXz
    case appleArchive
    /// A format ArchiveKit recognises and does not read.
    case unsupported(String)

    /// Anything not recognised as another format is handed to the ZIP reader,
    /// which also finds archives behind a self-extracting stub.
    public static func detect(at url: URL) throws -> ArchiveFormat {
        let file = try RandomAccessFile(url: url)
        let head = [UInt8](try file.read(at: 0, count: Int(min(file.size, 512))))
        return detect(head)
    }

    static func detect(_ head: [UInt8]) -> ArchiveFormat {
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head[0..<bytes.count]) == bytes }
        if starts([0x1F, 0x8B]) { return .tarGzip }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tarXz }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .unsupported("7z") }
        if starts(Array("Rar!\u{1A}\u{07}".utf8)) { return .unsupported("RAR") }
        if starts(Array("BZh".utf8)), head.count > 3, (0x31...0x39).contains(head[3]) { return .unsupported("bzip2") }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .unsupported("Zstandard") }
        if starts(Array("AEA1".utf8)) { return .unsupported("encrypted Apple Archive") }
        // Apple Archive: raw ("AA01") or compressed ("pbz" and a letter or digit).
        if starts(Array("AA01".utf8)) { return .appleArchive }
        if starts(Array("pbz".utf8)), head.count > 3, head[3].isASCIILetterOrDigit { return .appleArchive }
        if TarHeader.looksLikeHeader(head) { return .tar }
        return .zip
    }
}

private extension UInt8 {
    var isASCIILetterOrDigit: Bool {
        (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
    }
}
