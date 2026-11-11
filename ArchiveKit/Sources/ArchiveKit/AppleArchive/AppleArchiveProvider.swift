import Foundation
#if canImport(AppleArchive)
import AppleArchive
import System

/// An Apple Archive (`.aar`), read with the system's AppleArchive framework
/// (HLD §18.4).
///
/// Like compressed tar, an Apple Archive can only be read from the start,
/// so opening reads it once, in bounded chunks, reporting progress and
/// honouring cancellation, and keeps each file's data in a temporary spool
/// that later reads come from. Encrypted archives (`.aea`) are not read.
public actor AppleArchiveProvider: ArchiveProvider {
    public nonisolated let url: URL
    public nonisolated let entries: [ArchiveEntry]
    public nonisolated let warnings: [String]
    public nonisolated let sourceQuarantine: Data?
    public nonisolated let limits: ArchiveLimits

    private let spool: ArchiveSpool
    private let offsets: [UInt64]
    private let sizes: [UInt64]
    private let symlinkTargets: [Int: Data]

    static let readChunkSize = 128 * 1024

    private struct Record {
        var path: String
        var type: EntryType
        var size: UInt64
        var mode: UInt16
        var date: Date?
        var linkTarget: String?
        var offset: UInt64
    }

    public static func open(
        _ url: URL,
        limits: ArchiveLimits = ArchiveLimits(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AppleArchiveProvider {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let spool = try ArchiveSpool()
        var records: [Record] = []
        var warnings: [String] = []
        var special = 0

        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [], permissions: []) else {
            throw ArchiveError.io("“\(url.lastPathComponent)” could not be opened.")
        }
        defer { try? file.close() }
        let fileSize = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe).prefix(4))

        // Archives are usually compressed in blocks ("pbz…"); raw ones start "AA01".
        var source: ArchiveByteStream = file
        var decompression: ArchiveByteStream?
        if head.starts(with: Array("pbz".utf8)) {
            guard let stream = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw ArchiveError.notAnArchive }
            decompression = stream
            source = stream
        }
        defer { try? decompression?.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: source) else { throw ArchiveError.notAnArchive }
        defer { try? decoder.close() }

        var buffer = [UInt8](repeating: 0, count: readChunkSize)
        var entriesRead = 0
        do {
            while let header = try decoder.readHeader() {
                try Task.checkCancellation()
                entriesRead += 1
                guard case .string(_, let rawPath)? = header.field(forKey: .init("PAT")),
                      case .uint(_, let typeCode)? = header.field(forKey: .init("TYP"))
                else { continue }
                let path = TarIndexer.normalised(rawPath)
                var mode: UInt16 = 0
                if case .uint(_, let value)? = header.field(forKey: .init("MOD")) { mode = UInt16(truncatingIfNeeded: value & 0o7777) }
                var date: Date?
                if case .timespec(_, let value)? = header.field(forKey: .init("MTM")) {
                    date = plausibleDate(secondsSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1e9)
                }
                var type: EntryType
                switch typeCode {
                case 70: type = .file
                case 68: type = .directory
                case 76: type = .symlink
                default:
                    special += 1
                    continue
                }
                var link: String?
                if type == .symlink, case .string(_, let target)? = header.field(forKey: .init("LNK")) { link = target }

                var size: UInt64 = 0
                let offset = spool.size
                if type == .file, case .blob(_, let blobSize, _)? = header.field(forKey: .init("DAT")) {
                    size = blobSize
                    if blobSize > limits.maximumEntrySize {
                        // Listed, refused when read, and not kept.
                        try skipBlob(decoder, size: blobSize, buffer: &buffer)
                        size = blobSize
                        if !path.isEmpty {
                            records.append(Record(path: path, type: type, size: size, mode: mode, date: date, linkTarget: nil, offset: 0))
                        }
                        continue
                    }
                    var remaining = blobSize
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let count = Int(min(UInt64(buffer.count), remaining))
                        try buffer.withUnsafeMutableBytes { raw in
                            try decoder.readBlob(key: .init("DAT"), into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<count]))
                        }
                        try spool.append(Data(buffer[0..<count]))
                        remaining -= UInt64(count)
                    }
                    guard ArchiveSpool.hasRoom(for: 0) else {
                        throw ArchiveError.insufficientDiskSpace(required: spool.size, available: 0)
                    }
                }
                if !path.isEmpty {
                    records.append(Record(path: path, type: type, size: size, mode: mode, date: date, linkTarget: link, offset: offset))
                }
                if entriesRead % 200 == 0 || size > 1 << 20 {
                    let position = (try? file.seek(toOffset: 0, relativeTo: .current)) ?? 0
                    progress?(min(Double(position) / Double(max(fileSize, 1)), 0.99))
                    let consumed = UInt64(max(position, 1))
                    if spool.size > limits.compressionRatioThreshold, spool.size / consumed > limits.maximumCompressionRatio {
                        throw ArchiveError.exceedsLimits(
                            path: url.lastPathComponent,
                            reason: "its compression ratio is implausibly high, which suggests a ZIP bomb"
                        )
                    }
                }
            }
        } catch let error as ArchiveError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !records.isEmpty else { throw ArchiveError.notAnArchive }
            warnings.append(String(localized: "The archive is damaged after \(records.count) items; the rest cannot be listed.", bundle: .archiveKitStrings))
        }
        try spool.finish()
        progress?(1)
        if special > 0 {
            warnings.append(String(localized: "\(special) devices, pipes or other special files are not shown.", bundle: .archiveKitStrings))
        }
        ArchiveLog.parsing.info("Opened Apple Archive with \(records.count) items in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds, .seconds], width: .narrow)), privacy: .public)")
        return AppleArchiveProvider(url: url, limits: limits, spool: spool, records: records, warnings: warnings)
    }

    private static func skipBlob(_ decoder: ArchiveStream, size: UInt64, buffer: inout [UInt8]) throws {
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(buffer.count), remaining))
            try buffer.withUnsafeMutableBytes { raw in
                try decoder.readBlob(key: .init("DAT"), into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<count]))
            }
            remaining -= UInt64(count)
        }
    }

    private init(url: URL, limits: ArchiveLimits, spool: ArchiveSpool, records: [Record], warnings: [String]) {
        self.url = url
        self.limits = limits
        self.spool = spool
        self.warnings = warnings
        sourceQuarantine = Quarantine.attribute(of: url)
        var entries: [ArchiveEntry] = []
        var offsets: [UInt64] = []
        var sizes: [UInt64] = []
        var links: [Int: Data] = [:]
        for record in records {
            let id = entries.count
            var shown = record.type == .file ? record.size : 0
            if record.type == .symlink {
                let target = Data((record.linkTarget ?? "").utf8)
                links[id] = target
                shown = UInt64(target.count)
            }
            entries.append(ArchiveEntry(
                id: id, path: record.path, type: record.type,
                compressedSize: shown, uncompressedSize: shown,
                modificationDate: record.date, compressionMethod: .wholeArchive("Apple Archive"), crc32: nil,
                posixPermissions: record.mode, storageOffset: record.offset
            ))
            offsets.append(record.offset)
            sizes.append(record.size)
        }
        self.entries = entries
        self.offsets = offsets
        self.sizes = sizes
        symlinkTargets = links
    }

    // Neither format here is password-protected.
    public func setPassword(_ password: String?) async {}
    public func checkPassword(_ password: String, for entry: ArchiveEntry) async -> Bool? { nil }

    public func read(_ entry: ArchiveEntry, into consumer: (Data) throws -> Void) async throws {
        guard entries.indices.contains(entry.id), entries[entry.id] == entry else {
            throw ArchiveError.unknownEntry(path: entry.path)
        }
        switch entry.type {
        case .directory: return
        case .symlink:
            try consumer(symlinkTargets[entry.id] ?? Data())
            return
        case .file: break
        }
        try limits.check(entry)
        var done: UInt64 = 0
        while done < sizes[entry.id] {
            try Task.checkCancellation()
            let count = Int(min(UInt64(Self.readChunkSize), sizes[entry.id] - done))
            try consumer(try spool.read(at: offsets[entry.id] + done, count: count))
            done += UInt64(count)
        }
    }
}
#endif
