import Foundation

/// The kind of item an archive entry represents.
public enum EntryType: String, Sendable, Hashable {
    case file
    case directory
    case symlink
}

/// A compression method, independent of any particular archive format.
///
/// Every method is representable so that entries using unsupported methods
/// can still be listed and browsed (HLD §18.1). Only `isSupported` methods
/// can actually be read.
public enum CompressionMethod: Sendable, Hashable, CustomStringConvertible {
    case stored
    case deflate
    case deflate64
    case bzip2
    case lzma
    case zstd
    case xz
    case ppmd
    /// The whole archive is compressed as one stream (gzip, xz, Apple
    /// Archive), so entries have no compressed size of their own.
    case wholeArchive(String)
    case other(UInt16)

    /// Whether ArchiveKit can decode entries compressed with this method.
    public var isSupported: Bool {
        switch self {
        case .stored, .deflate, .deflate64, .lzma, .wholeArchive: return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .stored: return "Stored"
        case .deflate: return "Deflate"
        case .deflate64: return "Deflate64"
        case .bzip2: return "bzip2"
        case .lzma: return "LZMA"
        case .zstd: return "Zstandard"
        case .xz: return "XZ"
        case .ppmd: return "PPMd"
        case .wholeArchive(let name): return "\(name) (whole archive)"
        case .other(let raw): return "method \(raw)"
        }
    }
}

/// The strength of WinZip AES encryption.
public enum AESStrength: UInt8, Sendable, Hashable {
    case aes128 = 1
    case aes192 = 2
    case aes256 = 3

    public var keyLength: Int { Int(rawValue) * 8 + 8 }
    public var saltLength: Int { keyLength / 2 }
    public var bits: Int { keyLength * 8 }
}

/// How an entry's data is encrypted.
public enum EntryEncryption: Sendable, Hashable {
    /// The traditional PKWARE cipher: weak, but still the most common.
    /// `checkByte` is the last byte of the 12-byte header once decrypted,
    /// which tells most wrong passwords from the right one.
    case zipCrypto(checkByte: UInt8)
    /// WinZip AES (AE-1 keeps the CRC-32, AE-2 does not).
    case winZipAES(strength: AESStrength, version: Int)
    /// Some other scheme, such as PKWARE's strong encryption.
    case unsupported

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    /// Bytes stored around the compressed data: the header and, for AES,
    /// the authentication code.
    var overhead: UInt64 {
        switch self {
        case .zipCrypto: return 12
        case .winZipAES(let strength, _): return UInt64(strength.saltLength + 2 + 10)
        case .unsupported: return 0
        }
    }

    public var description: String {
        switch self {
        case .zipCrypto: return "ZipCrypto"
        case .winZipAES(let strength, _): return "AES-\(strength.bits)"
        case .unsupported: return "unsupported encryption"
        }
    }
}

/// A modification date from an archive's own count of seconds since 1970,
/// or nil when that is not finite or lies outside the years 1 to 9999.
///
/// tar's pax `mtime` accepts "inf" and "nan", and tar and Apple Archive
/// can declare values near 2^64 seconds. Such dates reach file system
/// calls that convert them to `time_t`, which traps for values out of range.
func plausibleDate(secondsSince1970 seconds: Double) -> Date? {
    guard seconds.isFinite, seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

/// A file, directory or symbolic link inside an archive.
///
/// Entries are format-independent: the UI only ever sees `ArchiveEntry`,
/// never a ZIP-specific type (HLD §3, §5).
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    /// Position of the entry within its archive. Stable for a given archive
    /// file, so it survives reloading the same archive.
    public let id: Int

    /// The entry's path inside the archive, using `/` as separator and with
    /// no trailing slash. This is the archive's own claim and is *not*
    /// guaranteed to be safe; use `PathSanitizer` before touching the
    /// filesystem.
    public let path: String

    public let type: EntryType

    public let compressedSize: UInt64
    public let uncompressedSize: UInt64

    public let modificationDate: Date?
    public let compressionMethod: CompressionMethod

    public let crc32: UInt32?

    /// True when the entry's data is encrypted (ZipCrypto or AES).
    public let isEncrypted: Bool

    /// How the data is encrypted, when it is and the archive says how.
    public let encryption: EntryEncryption?

    /// Unix permission bits (`0o7777` mask), when the archive records them.
    public let posixPermissions: UInt16?

    /// Format-specific location of the entry's data, so the engine can reach
    /// it without searching the archive again (HLD §5).
    let storageOffset: UInt64

    public init(
        id: Int,
        path: String,
        type: EntryType,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        modificationDate: Date?,
        compressionMethod: CompressionMethod,
        crc32: UInt32?,
        isEncrypted: Bool = false,
        encryption: EntryEncryption? = nil,
        posixPermissions: UInt16? = nil,
        storageOffset: UInt64 = 0
    ) {
        self.id = id
        self.path = path
        self.type = type
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.modificationDate = modificationDate
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.isEncrypted = isEncrypted || encryption != nil
        self.encryption = encryption
        self.posixPermissions = posixPermissions
        self.storageOffset = storageOffset
    }

    /// The last path component.
    public var name: String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// The file extension, lowercased, or an empty string.
    public var pathExtension: String {
        let name = self.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// True for `__MACOSX/` AppleDouble entries and `.DS_Store`-style
    /// metadata that macOS writes into archives (HLD §18.2).
    public var isMacOSMetadata: Bool {
        path == "__MACOSX" || path.hasPrefix("__MACOSX/")
    }

    /// Whether ArchiveKit is able to read this entry's contents, given the
    /// password if it needs one.
    public var isReadable: Bool {
        compressionMethod.isSupported && (isEncrypted ? encryption?.isSupported ?? false : true)
    }

    /// Whether reading this entry needs a password.
    public var needsPassword: Bool {
        isEncrypted && (encryption?.isSupported ?? false)
    }
}
