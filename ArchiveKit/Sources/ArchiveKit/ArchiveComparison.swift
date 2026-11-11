import Foundation

/// The differences between an archive and another archive or a folder
/// (HLD §20, Phase 5). Items are matched by path and compared by size and
/// CRC-32 from the directory, so nothing in an archive is decompressed.
/// Only a folder's files are read, and only those whose size already
/// matches an archive entry's.
public struct ArchiveComparison: Sendable {
    public enum Change: String, Sendable, CaseIterable {
        /// In the other side but not in this archive.
        case added
        /// In this archive but not in the other side.
        case removed
        /// In both, with a different size or checksum.
        case changed
    }

    public struct Item: Identifiable, Sendable, Hashable {
        public let path: String
        public let change: Change
        /// Size in this archive, if the item is there.
        public let archiveSize: UInt64?
        /// Size in the other archive or the folder, if the item is there.
        public let otherSize: UInt64?
        /// Position in `items`. Not the path: an archive can hold two items
        /// with the same path, and duplicate ids make SwiftUI lists fail.
        public internal(set) var id = 0
    }

    public enum Other: Sendable {
        case archive([ArchiveEntry])
        case folder(URL)
    }

    public let items: [Item]
    /// Items in both with the same size and checksum.
    public let unchangedCount: Int
    /// Items in both that match in size but whose checksum one side does not
    /// record (AES-2, or a damaged archive), so they could not be told apart.
    public let unverifiedCount: Int
    /// Symbolic links in a folder, which are not compared.
    public let skippedLinkCount: Int
    /// The single top-level folder dropped from this archive's paths, and
    /// from the other side's, so that a folder and an archive of the folder
    /// line up.
    public let archivePrefix: String?
    public let otherPrefix: String?

    public func count(_ change: Change) -> Int { items.filter { $0.change == change }.count }
    public var isIdentical: Bool { items.isEmpty }

    // MARK: Comparing

    struct File: Sendable {
        var path: String
        var size: UInt64
        var crc32: UInt32?
        /// For folders, where to read the checksum from if it is needed.
        var url: URL?
    }

    public static func compare(
        archive entries: [ArchiveEntry],
        with other: Other,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ArchiveComparison {
        let mine = Self.files(of: entries)
        var skippedLinks = 0
        let theirs: [File]
        switch other {
        case .archive(let otherEntries):
            theirs = Self.files(of: otherEntries)
        case .folder(let url):
            (theirs, skippedLinks) = try Self.scan(url)
        }

        // Pick the alignment that matches the most paths: as they are, or
        // with a lone top-level folder removed from one side or both.
        let mineTop = loneTopLevelFolder(mine)
        let theirsTop = loneTopLevelFolder(theirs)
        var best: (mine: String?, theirs: String?, matches: Int) = (nil, nil, -1)
        for candidate in [(String?.none, String?.none), (mineTop, nil), (nil, theirsTop), (mineTop, theirsTop)] {
            if (candidate.0 != nil && mineTop == nil) || (candidate.1 != nil && theirsTop == nil) { continue }
            let left = Set(mine.map { key($0.path, dropping: candidate.0) })
            let matches = theirs.reduce(0) { $0 + (left.contains(key($1.path, dropping: candidate.1)) ? 1 : 0) }
            if matches > best.matches { best = (candidate.0, candidate.1, matches) }
        }

        var byKey: [String: File] = [:]
        for file in mine { byKey[key(file.path, dropping: best.mine)] = file }
        var items: [Item] = []
        var unchanged = 0
        var unverified = 0
        var seen = Set<String>()
        var examined = 0

        for file in theirs {
            try Task.checkCancellation()
            let k = key(file.path, dropping: best.theirs)
            seen.insert(k)
            examined += 1
            if examined % 200 == 0 { progress?(examined) }
            guard let match = byKey[k] else {
                items.append(Item(path: display(file.path, dropping: best.theirs), change: .added, archiveSize: nil, otherSize: file.size))
                continue
            }
            let name = display(match.path, dropping: best.mine)
            if match.size != file.size {
                items.append(Item(path: name, change: .changed, archiveSize: match.size, otherSize: file.size))
                continue
            }
            // Same size: settle it by checksum, reading a folder's file only now.
            let theirCRC = try file.crc32 ?? file.url.map { try checksum(of: $0) }
            if let mineCRC = match.crc32, let theirCRC {
                if mineCRC == theirCRC { unchanged += 1 }
                else { items.append(Item(path: name, change: .changed, archiveSize: match.size, otherSize: file.size)) }
            } else {
                unverified += 1
            }
        }
        for (k, file) in byKey where !seen.contains(k) {
            items.append(Item(path: display(file.path, dropping: best.mine), change: .removed, archiveSize: file.size, otherSize: nil))
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for index in items.indices { items[index].id = index }
        return ArchiveComparison(
            items: items, unchangedCount: unchanged, unverifiedCount: unverified, skippedLinkCount: skippedLinks,
            archivePrefix: best.mine, otherPrefix: best.theirs
        )
    }

    // MARK: Helpers

    private static func files(of entries: [ArchiveEntry]) -> [File] {
        entries.compactMap { entry in
            guard entry.type != .directory, !entry.isMacOSMetadata else { return nil }
            return File(path: entry.path, size: entry.uncompressedSize, crc32: entry.crc32)
        }
    }

    /// The name of the one folder that holds everything, if there is one.
    private static func loneTopLevelFolder(_ files: [File]) -> String? {
        var top: String?
        for file in files {
            let parts = file.path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            if top == nil { top = String(parts[0]) } else if top != String(parts[0]) { return nil }
        }
        return top
    }

    private static func display(_ path: String, dropping prefix: String?) -> String {
        guard let prefix, path.hasPrefix(prefix + "/") else { return path }
        return String(path.dropFirst(prefix.count + 1))
    }

    /// Paths compare equal across Unicode normalisation forms, which differ
    /// between ZIP files and macOS file systems.
    private static func key(_ path: String, dropping prefix: String?) -> String {
        display(path, dropping: prefix).precomposedStringWithCanonicalMapping
    }

    private static func scan(_ folder: URL) throws -> ([File], Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { throw ArchiveError.io("The folder could not be read.") }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [File] = []
        var links = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { links += 1; continue }
            guard values?.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { continue }
            files.append(File(path: String(path.dropFirst(root.count + 1)), size: UInt64(values?.fileSize ?? 0), crc32: nil, url: url))
        }
        return (files, links)
    }

    private static func checksum(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = CRC32()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            crc.update(chunk)
        }
        return crc.value
    }
}
