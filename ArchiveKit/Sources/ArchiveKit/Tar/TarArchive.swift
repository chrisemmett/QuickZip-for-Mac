import Foundation

/// A tar archive, plain or compressed with gzip or xz (HLD §18.4).
///
/// Plain tar is indexed by reading its headers and skipping the data, so
/// opening is quick and nothing is decompressed. Compressed tar has no
/// directory and can only be read from the start, so opening decompresses
/// it once, in bounded chunks, reporting progress and honouring
/// cancellation, writing each item's data to a temporary spool that later
/// reads come from. The compressed file itself is never written.
public actor TarArchive: ArchiveProvider {
    public enum Compression: Sendable {
        case none, gzip, xz

        var name: String {
            switch self {
            case .none: return "tar"
            case .gzip: return "gzip"
            case .xz: return "xz"
            }
        }
    }

    public nonisolated let url: URL
    public nonisolated let entries: [ArchiveEntry]
    public nonisolated let warnings: [String]
    public nonisolated let sourceQuarantine: Data?
    public nonisolated let limits: ArchiveLimits

    private enum Storage {
        case file(RandomAccessFile)
        case spool(ArchiveSpool)

        func read(at offset: UInt64, count: Int) throws -> Data {
            switch self {
            case .file(let file): return try file.read(at: offset, count: count)
            case .spool(let spool): return try spool.read(at: offset, count: count)
            }
        }

        var size: UInt64 {
            switch self {
            case .file(let file): return file.size
            case .spool(let spool): return spool.size
            }
        }
    }

    private let storage: Storage
    private let offsets: [UInt64]
    private let sizes: [UInt64]
    private let symlinkTargets: [Int: Data]
    private let unreadable: [Int: String]

    static let readChunkSize = 128 * 1024

    // MARK: Opening

    public static func open(
        _ url: URL,
        compression: Compression,
        limits: ArchiveLimits = ArchiveLimits(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TarArchive {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let storage: Storage
        let indexed: (records: [TarRecord], warnings: [String], special: Int)
        switch compression {
        case .none:
            let file = try RandomAccessFile(url: url)
            indexed = try indexFile(file, progress: progress)
            storage = .file(file)
        case .gzip, .xz:
            let spool = try ArchiveSpool()
            indexed = try await indexStream(url, compression: compression, spool: spool, limits: limits, progress: progress)
            try spool.finish()
            storage = .spool(spool)
        }
        progress?(1)
        ArchiveLog.parsing.info("Opened \(compression.name, privacy: .public) with \(indexed.records.count) items in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds, .seconds], width: .narrow)), privacy: .public)")
        return TarArchive(url: url, compression: compression, limits: limits, storage: storage, indexed: indexed)
    }

    private init(
        url: URL, compression: Compression, limits: ArchiveLimits, storage: Storage,
        indexed: (records: [TarRecord], warnings: [String], special: Int)
    ) {
        self.url = url
        self.limits = limits
        self.storage = storage
        sourceQuarantine = Quarantine.attribute(of: url)

        var warnings = indexed.warnings
        if indexed.special > 0 {
            warnings.append(String(localized: "\(indexed.special) devices, pipes or other special files are not shown.", bundle: .archiveKitStrings))
        }

        // Hard links share the data of the entry they name.
        var latestByPath: [String: Int] = [:]
        var entries: [ArchiveEntry] = []
        var offsets: [UInt64] = []
        var sizes: [UInt64] = []
        var links: [Int: Data] = [:]
        var unreadable: [Int: String] = [:]
        let method: CompressionMethod = compression == .none ? .stored : .wholeArchive(compression.name)

        for record in indexed.records {
            let id = entries.count
            var offset = record.dataOffset
            var size = record.size
            var dataReason: String?
            if record.isHardLink {
                if let target = record.linkTarget.flatMap({ latestByPath[$0] }) {
                    offset = offsets[target]
                    size = sizes[target]
                    dataReason = unreadable[target]
                } else {
                    size = 0
                    dataReason = String(localized: "the item it links to is not in the archive", bundle: .archiveKitStrings)
                    warnings.append(String(localized: "A link points to an item that is not in the archive.", bundle: .archiveKitStrings))
                }
            }
            if record.isSparse {
                dataReason = String(localized: "sparse files are not supported", bundle: .archiveKitStrings)
            }
            var shownSize = record.type == .file ? (record.realSize ?? size) : 0
            if record.type == .symlink {
                let target = Data((record.linkTarget ?? "").utf8)
                links[id] = target
                shownSize = UInt64(target.count)
            }
            if let dataReason { unreadable[id] = dataReason }
            entries.append(ArchiveEntry(
                id: id,
                path: record.path,
                type: record.type,
                compressedSize: shownSize,
                uncompressedSize: shownSize,
                modificationDate: record.modificationDate,
                compressionMethod: method,
                crc32: nil,
                posixPermissions: record.mode,
                storageOffset: offset
            ))
            offsets.append(offset)
            sizes.append(size)
            if record.type == .file { latestByPath[record.path] = id }
        }
        self.entries = entries
        self.offsets = offsets
        self.sizes = sizes
        symlinkTargets = links
        self.unreadable = unreadable
        self.warnings = warnings
    }

    // MARK: Indexing

    private static func indexFile(
        _ file: RandomAccessFile, progress: (@Sendable (Double) -> Void)?
    ) throws -> (records: [TarRecord], warnings: [String], special: Int) {
        var indexer = TarIndexer()
        var warnings: [String] = []
        var position: UInt64 = 0
        let block = UInt64(TarHeader.blockSize)
        func padded(_ size: UInt64) -> UInt64 { (size + block - 1) / block * block }
        var count = 0

        scan: while position + block <= file.size {
            try Task.checkCancellation()
            let header = [UInt8](try file.read(at: position, count: TarHeader.blockSize))
            let next: TarIndexer.Next
            do {
                next = try indexer.header(header)
            } catch {
                if position == 0 { throw ArchiveError.notAnArchive }
                warnings.append(String(localized: "The archive is damaged after \(indexer.records.count) items; the rest cannot be listed.", bundle: .archiveKitStrings))
                break
            }
            position += block
            switch next {
            case .end:
                break scan
            case .metadata(let kind, let size):
                guard position + UInt64(size) <= file.size else {
                    warnings.append(String(localized: "The archive ends unexpectedly.", bundle: .archiveKitStrings))
                    break scan
                }
                indexer.metadata(kind: kind, data: [UInt8](try file.read(at: position, count: size)))
                position += padded(UInt64(size))
            case .skip(let size):
                // `position` never passes the end of the file, so this
                // subtraction is safe where `position + size` could overflow.
                guard size <= file.size - position else {
                    position = file.size
                    break scan
                }
                position += padded(size)
            case .entry(let size):
                if size > file.size - position {
                    indexer.commit(dataOffset: position)
                    indexer.truncateLast(to: file.size - position)
                    warnings.append(String(localized: "The archive ends in the middle of an item, which is cut short.", bundle: .archiveKitStrings))
                    break scan
                }
                indexer.commit(dataOffset: position)
                position += padded(size)
            }
            count += 1
            if count % 2_000 == 0 { progress?(Double(position) / Double(max(file.size, 1))) }
        }
        if indexer.records.isEmpty && warnings.isEmpty && position == 0 && file.size > 0 {
            throw ArchiveError.notAnArchive
        }
        return (indexer.records, warnings, indexer.skippedSpecialFiles)
    }

    private static func indexStream(
        _ url: URL, compression: Compression, spool: ArchiveSpool, limits: ArchiveLimits,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (records: [TarRecord], warnings: [String], special: Int) {
        let file = try RandomAccessFile(url: url)
        let decoder: WholeStreamDecoder
        switch compression {
        case .gzip: decoder = try GzipStreamDecoder(path: url.lastPathComponent)
        case .xz: decoder = try XZStreamDecoder(path: url.lastPathComponent)
        case .none: preconditionFailure("not a stream")
        }
        let parser = TarStreamParser(spool: spool, limits: limits)
        var position: UInt64 = 0
        var warnings: [String] = []
        let chunkSize = 256 * 1024

        do {
            reading: while position < file.size || position == 0 {
                try Task.checkCancellation()
                let count = Int(min(UInt64(chunkSize), file.size - position))
                let chunk = try file.read(at: position, count: count)
                position += UInt64(count)
                let isFinal = position >= file.size
                do {
                    try decoder.process(chunk, isFinal: isFinal) { output in
                        try parser.feed(output)
                        // The same rule as for one entry, applied as the data
                        // comes out: a stream that expands past what any real
                        // compressor produces is a bomb, and is stopped before
                        // it fills the disk.
                        if parser.totalOut > limits.compressionRatioThreshold,
                           parser.totalOut / max(position, 1) > limits.maximumCompressionRatio {
                            throw ArchiveError.exceedsLimits(
                                path: url.lastPathComponent,
                                reason: "its compression ratio is implausibly high, which suggests a ZIP bomb"
                            )
                        }
                    }
                } catch is TarStreamParser.Stop {
                    break reading
                }
                progress?(Double(position) / Double(max(file.size, 1)))
                if isFinal { break }
            }
        } catch let error as ArchiveError {
            // A damaged stream keeps what was read before the damage; nothing
            // read at all means it is not an archive of this kind.
            guard case .corruptData = error, !parser.indexer.records.isEmpty else { throw error }
            warnings.append(String(localized: "The compressed data is damaged after \(parser.indexer.records.count) items; the rest cannot be listed.", bundle: .archiveKitStrings))
        }
        parser.finish()
        warnings += parser.warnings
        return (parser.indexer.records, warnings, parser.indexer.skippedSpecialFiles)
    }

    // Neither format here is password-protected.
    public func setPassword(_ password: String?) async {}
    public func checkPassword(_ password: String, for entry: ArchiveEntry) async -> Bool? { nil }

    // MARK: Reading

    public func read(_ entry: ArchiveEntry, into consumer: (Data) throws -> Void) async throws {
        guard entries.indices.contains(entry.id), entries[entry.id] == entry else {
            throw ArchiveError.unknownEntry(path: entry.path)
        }
        switch entry.type {
        case .directory:
            return
        case .symlink:
            try consumer(symlinkTargets[entry.id] ?? Data())
            return
        case .file:
            break
        }
        try limits.check(entry)
        if let reason = unreadable[entry.id] {
            throw ArchiveError.corruptData(path: entry.path, reason: reason)
        }
        let size = sizes[entry.id]
        var done: UInt64 = 0
        while done < size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(Self.readChunkSize), size - done))
            try consumer(try storage.read(at: offsets[entry.id] + done, count: count))
            done += UInt64(count)
        }
    }
}
