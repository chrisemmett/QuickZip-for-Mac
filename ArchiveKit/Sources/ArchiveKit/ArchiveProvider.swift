import Foundation

/// A read-only archive, independent of its on-disk format (HLD §4).
///
/// The UI talks only to this protocol, so adding a format means adding a
/// provider rather than changing the UI. Providers are expected to be actors:
/// every requirement is `async` so that parsing and decompression never run
/// on the main actor (HLD §15).
///
/// Opening a provider may itself be slow for formats without a central
/// directory (compressed tar, HLD §18.4); that work belongs in the provider's
/// own async factory, which should honour task cancellation.
public protocol ArchiveProvider: AnyObject, Sendable {
    /// Every entry in the archive, in archive order.
    var entries: [ArchiveEntry] { get async }

    /// Non-fatal problems found while opening, for example a partly damaged
    /// directory from which only some entries could be recovered.
    var warnings: [String] { get async }

    /// The archive file's `com.apple.quarantine` extended attribute, if it
    /// has one. Every file written from the archive must carry it (HLD §13).
    var sourceQuarantine: Data? { get }

    /// The ZIP-bomb limits `read(_:into:)` enforces. Entries exceeding them
    /// are refused before any data is produced.
    var limits: ArchiveLimits { get }

    /// Entries that share data with other entries, which is how overlapping
    /// ZIP bombs are built. Providers refuse to read them. Formats that
    /// cannot have such entries need not provide this.
    var overlappingEntryIDs: Set<Int> { get }

    /// Sets the password used to read encrypted entries; nil clears it.
    /// Formats without encryption ignore it. (No default implementation: a
    /// default in an extension is chosen over an actor's own method.)
    func setPassword(_ password: String?) async

    /// Whether `password` opens `entry`: nil when the entry has no
    /// password or the format cannot tell.
    func checkPassword(_ password: String, for entry: ArchiveEntry) async -> Bool?

    /// Streams the decompressed contents of `entry` to `consumer` in chunks
    /// of bounded size, validating the checksum once the stream ends.
    ///
    /// Throws `CancellationError` if the calling task is cancelled.
    func read(
        _ entry: ArchiveEntry,
        into consumer: (Data) throws -> Void
    ) async throws
}

extension ArchiveProvider {
    public var overlappingEntryIDs: Set<Int> { [] }

    /// The complete decompressed contents of `entry`.
    ///
    /// Loads the whole entry into memory; prefer `read(_:into:)` or
    /// `extract(_:to:)` for entries of arbitrary size.
    public func contents(of entry: ArchiveEntry) async throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(clamping: min(entry.uncompressedSize, 64 << 20)))
        try await read(entry) { data.append($0) }
        return data
    }

    /// Extracts `entry` beneath `destination`, recreating its archive path.
    ///
    /// Returns the URL of the extracted item. See `ArchiveExtractor` for the
    /// safety rules applied.
    @discardableResult
    public func extract(
        _ entry: ArchiveEntry,
        to destination: URL,
        options: ExtractionOptions = ExtractionOptions()
    ) async throws -> URL? {
        let extractor = try ArchiveExtractor(destination: destination, options: options)
        return try await extractor.extract(entry, from: self)
    }
}
