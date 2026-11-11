import Foundation

/// How to open an archive, whatever its format.
public struct ArchiveOpenOptions: Sendable {
    /// For ZIP names not marked as UTF-8 (View → Text Encoding).
    public var filenameEncoding: FilenameEncoding
    public var limits: ArchiveLimits

    public init(filenameEncoding: FilenameEncoding = .automatic, limits: ArchiveLimits = ArchiveLimits()) {
        self.filenameEncoding = filenameEncoding
        self.limits = limits
    }
}

/// Opens an archive by looking at what it is (HLD §18.4). Opening may be
/// slow for formats read from the start (compressed tar, Apple Archive):
/// `progress` is called with the fraction done, and cancelling the task
/// stops it.
public enum ArchiveOpener {
    public static func open(
        _ url: URL,
        options: ArchiveOpenOptions = ArchiveOpenOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> any ArchiveProvider {
        switch try ArchiveFormat.detect(at: url) {
        case .zip:
            return try await ZIPArchive.open(url, options: ZIPArchiveOptions(filenameEncoding: options.filenameEncoding, limits: options.limits))
        case .tar:
            return try await TarArchive.open(url, compression: .none, limits: options.limits, progress: progress)
        case .tarGzip:
            return try await TarArchive.open(url, compression: .gzip, limits: options.limits, progress: progress)
        case .tarXz:
            return try await TarArchive.open(url, compression: .xz, limits: options.limits, progress: progress)
        case .appleArchive:
            #if canImport(AppleArchive)
            return try await AppleArchiveProvider.open(url, limits: options.limits, progress: progress)
            #else
            throw ArchiveError.unsupportedFormat(path: url.lastPathComponent, format: "Apple Archive")
            #endif
        case .unsupported(let name):
            throw ArchiveError.unsupportedFormat(path: url.lastPathComponent, format: name)
        }
    }
}
