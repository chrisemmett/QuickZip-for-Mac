import Foundation

/// Errors raised while opening, reading or extracting an archive.
///
/// Every case carries enough context for a specific, user-facing message;
/// failures are never generic or silent (HLD §18.1).
public enum ArchiveError: Error, Equatable, Sendable {
    /// The file is not a recognisable archive.
    case notAnArchive
    /// A structure inside the archive is invalid or points outside the file.
    case malformed(String)
    /// The entry uses a compression method ArchiveKit cannot decode.
    case unsupportedCompressionMethod(path: String, method: CompressionMethod)
    /// The entry is encrypted in a way ArchiveKit cannot decrypt.
    case encryptedEntry(path: String)
    /// The entry needs a password and none has been given.
    case passwordRequired(path: String)
    /// The password given does not open the entry.
    case invalidPassword(path: String)
    /// The decompressed data does not match the stored CRC-32.
    case checksumMismatch(path: String, expected: UInt32, actual: UInt32)
    /// The decompressed data is not the size the archive declared.
    case sizeMismatch(path: String, expected: UInt64, actual: UInt64)
    /// The compressed stream is invalid.
    case corruptData(path: String, reason: String)
    /// The entry exceeds the configured safety limits (zip bomb protection).
    case exceedsLimits(path: String, reason: String)
    /// The entry's path would escape the extraction directory.
    case unsafePath(String)
    /// A symlink entry points outside the extraction directory.
    case unsafeSymlink(path: String, target: String)
    /// The operation needs a different kind of entry.
    case wrongEntryType(path: String, expected: EntryType)
    /// The entry does not belong to this archive.
    case unknownEntry(path: String)
    /// A file already exists at the extraction destination.
    case destinationExists(String)
    /// The destination volume does not have room for the extracted items.
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    /// The file is an archive format ArchiveKit does not read, such as 7z or
    /// RAR, which need third-party decoders (HLD §18.4).
    case unsupportedFormat(path: String, format: String)
    /// An underlying filesystem operation failed.
    case io(String)
}

extension ArchiveError: LocalizedError {
    /// User-facing text, from the package's String Catalog (HLD §18.5).
    /// Reasons carried by `malformed`, `corruptData` and `exceedsLimits` are
    /// technical detail and stay in English.
    public var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return String(localized: "The file is not a supported archive.", bundle: .archiveKitStrings)
        case .malformed(let reason):
            return String(localized: "The archive is damaged: \(reason).", bundle: .archiveKitStrings)
        case .unsupportedCompressionMethod(let path, let method):
            return String(localized: "“\(path)” is compressed with \(method.description), which is not supported.", bundle: .archiveKitStrings)
        case .encryptedEntry(let path):
            return String(localized: "“\(path)” uses an encryption method that is not supported.", bundle: .archiveKitStrings)
        case .passwordRequired(let path):
            return String(localized: "“\(path)” is password-protected. Enter the password to open it.", bundle: .archiveKitStrings)
        case .invalidPassword(let path):
            return String(localized: "The password does not open “\(path)”.", bundle: .archiveKitStrings)
        case .checksumMismatch(let path, _, _):
            return String(localized: "“\(path)” is corrupt: its checksum does not match.", bundle: .archiveKitStrings)
        case .sizeMismatch(let path, let expected, let actual):
            return String(localized: "“\(path)” is corrupt: expected \(expected) bytes but found \(actual).", bundle: .archiveKitStrings)
        case .corruptData(let path, let reason):
            return String(localized: "“\(path)” is corrupt: \(reason).", bundle: .archiveKitStrings)
        case .exceedsLimits(let path, let reason):
            return String(localized: "“\(path)” was not opened because \(reason).", bundle: .archiveKitStrings)
        case .unsafePath(let path):
            return String(localized: "“\(path)” would be written outside the destination folder, so it was skipped.", bundle: .archiveKitStrings)
        case .unsafeSymlink(let path, let target):
            return String(localized: "“\(path)” is a link to “\(target)”, outside the destination folder, so it was skipped.", bundle: .archiveKitStrings)
        case .wrongEntryType(let path, let expected):
            return String(localized: "“\(path)” is not a \(expected.rawValue).", bundle: .archiveKitStrings)
        case .unknownEntry(let path):
            return String(localized: "“\(path)” is not part of this archive.", bundle: .archiveKitStrings)
        case .destinationExists(let path):
            return String(localized: "“\(path)” already exists.", bundle: .archiveKitStrings)
        case .insufficientDiskSpace(let required, let available):
            return String(localized: "There is not enough space: \(required) bytes are needed but only \(available) are available.", bundle: .archiveKitStrings)
        case .unsupportedFormat(let path, let format):
            return String(localized: "“\(path)” is a \(format) archive. QuickZip opens ZIP, tar (plain, .gz and .xz) and Apple Archive files; \(format) needs software it does not include.", bundle: .archiveKitStrings)
        case .io(let reason):
            return reason
        }
    }
}
