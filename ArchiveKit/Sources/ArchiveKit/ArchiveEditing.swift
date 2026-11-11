import Foundation

/// A file, folder or symbolic link on disk to be added to an archive.
public struct ArchiveAddition: Sendable, Hashable {
    /// The item on disk. Folders are added with everything inside them;
    /// symbolic links are stored as links, not followed.
    public var source: URL
    /// Where the item goes in the archive: a `/`-separated path with no
    /// leading or trailing slash.
    public var path: String

    public init(source: URL, path: String) {
        self.source = source
        self.path = path
    }
}

/// An archive that can write a modified copy of itself.
///
/// The archive is never changed in place: `rewrite` writes a complete new
/// archive to `destination`, and replacing the original with it is the
/// caller's job. A failure part-way therefore never damages the original.
public protocol RewritableArchive: ArchiveProvider {
    /// Why this archive cannot be rewritten (for example because it is
    /// damaged), or nil if it can.
    var rewriteBlocker: String? { get }

    /// Writes a copy of the archive to `destination` without the entries in
    /// `removing` and with `adding` appended. Entries that are kept are
    /// copied exactly, without being decompressed, so encrypted entries and
    /// unsupported compression methods survive unchanged.
    ///
    /// `destination` must not exist. It is left incomplete if this throws;
    /// the caller should delete it. Throws `CancellationError` if the task
    /// is cancelled.
    func rewrite(
        to destination: URL,
        removing: Set<ArchiveEntry.ID>,
        adding: [ArchiveAddition]
    ) async throws
}
