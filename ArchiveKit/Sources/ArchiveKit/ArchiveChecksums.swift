import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

extension ArchiveProvider {
    /// The SHA-256 of `entry`'s decompressed contents as lowercase hex,
    /// computed by streaming it through CryptoKit in bounded chunks
    /// (HLD §20, Phase 3 "Integrity information"). Throws as `read` does,
    /// so a corrupt entry never yields a checksum.
    public func sha256(of entry: ArchiveEntry) async throws -> String {
        var hasher = SHA256()
        try await read(entry) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A checksum list for `entries` in the format `shasum -a 256 -c`
    /// reads: the hash, two spaces, the path. Folders are left out, and so
    /// are entries that cannot be read (encrypted or unsupported), which
    /// are returned in `skipped` with those that failed.
    public func checksumList(
        for entries: [ArchiveEntry],
        progress: ((Int) -> Void)? = nil
    ) async throws -> (text: String, skipped: [ArchiveEntry]) {
        var lines: [String] = []
        var skipped: [ArchiveEntry] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            defer { progress?(index + 1) }
            guard entry.type == .file else { continue }
            guard entry.isReadable else {
                skipped.append(entry)
                continue
            }
            do {
                // The list is line-oriented: a newline in a name would forge a line.
                let path = entry.path.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                lines.append("\(try await sha256(of: entry))  \(path)")
            } catch let error as ArchiveError {
                _ = error
                skipped.append(entry)
            }
        }
        return (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), skipped)
    }
}
