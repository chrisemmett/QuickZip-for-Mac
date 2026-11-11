import Foundation
import os

/// `os.Logger` categories (HLD §18.5).
///
/// Archive contents and passwords are never logged: not item names, not
/// paths, not file data. Messages carry counts, sizes, offsets, method
/// names and error kinds only, so a log can be shared without exposing what
/// an archive holds. Read them with
/// `log stream --predicate 'subsystem == "QuickZip.ArchiveKit"'`.
public enum ArchiveLog {
    public static let subsystem = "QuickZip.ArchiveKit"

    /// Locating and reading the directory, recovering damaged archives.
    public static let parsing = Logger(subsystem: subsystem, category: "parsing")
    /// Writing items to disk, and rewriting archives.
    public static let extraction = Logger(subsystem: subsystem, category: "extraction")
    /// Preparing items for Quick Look and Open.
    public static let preview = Logger(subsystem: subsystem, category: "preview")
}

extension ArchiveError {
    /// A short, content-free name for the kind of error, safe to log.
    public var logKind: String {
        switch self {
        case .notAnArchive: return "notAnArchive"
        case .malformed: return "malformed"
        case .unsupportedCompressionMethod: return "unsupportedCompressionMethod"
        case .encryptedEntry: return "encryptedEntry"
        case .passwordRequired: return "passwordRequired"
        case .invalidPassword: return "invalidPassword"
        case .checksumMismatch: return "checksumMismatch"
        case .sizeMismatch: return "sizeMismatch"
        case .corruptData: return "corruptData"
        case .exceedsLimits: return "exceedsLimits"
        case .unsafePath: return "unsafePath"
        case .unsafeSymlink: return "unsafeSymlink"
        case .wrongEntryType: return "wrongEntryType"
        case .unknownEntry: return "unknownEntry"
        case .destinationExists: return "destinationExists"
        case .insufficientDiskSpace: return "insufficientDiskSpace"
        case .unsupportedFormat: return "unsupportedFormat"
        case .io: return "io"
        }
    }
}
