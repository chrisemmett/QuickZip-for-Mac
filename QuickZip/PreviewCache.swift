import Foundation
import ArchiveKit
import os

/// Temporary copies of archive entries for previewing (HLD §9).
///
/// Quick Look needs a file on disk, so an entry is decompressed into the
/// app's temporary directory the first time it is previewed and reused after
/// that. Files are written through `ArchiveExtractor`, so the archive's
/// quarantine attribute is applied to them as it is to explicit extractions
/// (HLD §13). Everything is deleted when the archive is closed.
actor PreviewCache {
    /// Parent of every window's cache, cleared at launch in case a previous
    /// run ended without cleaning up.
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Previews", isDirectory: true)

    private let directory = PreviewCache.rootDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var files: [ArchiveEntry.ID: URL] = [:]

    /// A file holding the contents of `entry`, decompressing it if needed.
    /// Cancelling the calling task stops decompression and removes the
    /// partial file.
    func file(for entry: ArchiveEntry, in archive: any ArchiveProvider) async throws -> URL {
        if let url = files[entry.id], FileManager.default.fileExists(atPath: url.path) {
            ArchiveLog.preview.debug("Preview reused")
            return url
        }
        // Names and contents are never logged (HLD §18.5).
        ArchiveLog.preview.info("Preparing preview: \(entry.uncompressedSize) bytes, \(entry.compressionMethod.description, privacy: .public)")
        // A folder per request, so overlapping requests never collide.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let extractor = try ArchiveExtractor(
                destination: folder,
                options: ExtractionOptions(conflictPolicy: .replace, restorePermissions: false)
            )
            guard let url = try await extractor.extract(entry, from: archive) else {
                throw ArchiveError.io("“\(entry.name)” could not be prepared for preview.")
            }
            files[entry.id] = url
            return url
        } catch {
            if error is CancellationError {
                ArchiveLog.preview.debug("Preview cancelled")
            } else if let error = error as? ArchiveError {
                ArchiveLog.preview.error("Preview failed: \(error.logKind, privacy: .public)")
            } else {
                ArchiveLog.preview.error("Preview failed: \(type(of: error), privacy: .public)")
            }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Deletes every preview file written by this cache.
    func removeAll() {
        files = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
