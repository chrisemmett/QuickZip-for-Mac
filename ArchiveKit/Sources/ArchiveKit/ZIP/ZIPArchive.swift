import Foundation

/// Options for opening a ZIP archive.
public struct ZIPArchiveOptions: Sendable, Hashable {
    /// How to decode names not marked as UTF-8 (View → Text Encoding).
    public var filenameEncoding: FilenameEncoding
    public var limits: ArchiveLimits

    public init(filenameEncoding: FilenameEncoding = .automatic, limits: ArchiveLimits = ArchiveLimits()) {
        self.filenameEncoding = filenameEncoding
        self.limits = limits
    }
}

/// A ZIP archive (HLD §6, §7, §15).
///
/// Opening reads only the central directory. Entry data is located,
/// decompressed and CRC-checked on demand, in bounded chunks. The archive
/// itself is never written to; `rewrite(to:removing:adding:)` writes a
/// modified copy elsewhere.
public actor ZIPArchive: RewritableArchive {
    public nonisolated let url: URL
    public nonisolated let options: ZIPArchiveOptions
    public nonisolated let entries: [ArchiveEntry]
    public nonisolated let warnings: [String]
    public nonisolated let sourceQuarantine: Data?
    public nonisolated var limits: ArchiveLimits { options.limits }
    public nonisolated let rewriteBlocker: String?
    /// The legacy encoding detected for names that are not UTF-8, when the
    /// archive was opened with `.automatic` and one fits better than CP437
    /// (View → Text Encoding shows it).
    public nonisolated let detectedFilenameEncoding: FilenameEncoding?

    let file: RandomAccessFile
    /// No entry's data may extend past this offset (the central directory,
    /// or the end of the file for recovered archives).
    let dataLimit: UInt64
    /// Entries whose data overlaps another's: a hallmark of "overlapping"
    /// ZIP bombs, so they are never decompressed.
    public nonisolated let overlappingEntryIDs: Set<Int>
    /// Each entry's directory record, by entry id; nil for an archive
    /// recovered without its directory.
    nonisolated let directoryRecords: [Data]?
    nonisolated let comment: Data

    static let readChunkSize = 128 * 1024

    /// The password for encrypted entries, as UTF-8. Held in memory for as
    /// long as the archive is open; never logged or written anywhere.
    var password: [UInt8]?

    /// Sets (or with nil, clears) the password used to read encrypted
    /// entries. Nothing is checked until an entry is read; see
    /// `checkPassword(_:for:)`.
    public func setPassword(_ password: String?) {
        self.password = password.map { Array($0.utf8) }
    }

    private init(
        url: URL,
        options: ZIPArchiveOptions,
        file: RandomAccessFile,
        directory: ParsedDirectory
    ) {
        self.url = url
        self.options = options
        self.file = file
        self.entries = directory.entries
        self.dataLimit = directory.dataLimit
        let overlapping = Self.findOverlappingEntries(directory.entries)
        self.overlappingEntryIDs = overlapping
        var warnings = directory.warnings
        if !overlapping.isEmpty {
            warnings.append(String(localized: "\(overlapping.count) items share data with other items, which is typical of a ZIP bomb. They cannot be opened.", bundle: .archiveKitStrings))
        }
        self.warnings = warnings
        self.sourceQuarantine = Quarantine.attribute(of: url)
        self.directoryRecords = directory.records
        self.comment = directory.comment
        self.detectedFilenameEncoding = directory.detectedEncoding
        // Rewriting copies entries as they are, so anything not fully
        // understood would be lost or carried along.
        if directory.records == nil {
            rewriteBlocker = String(localized: "its directory is missing or damaged", bundle: .archiveKitStrings)
        } else if !directory.warnings.isEmpty {
            rewriteBlocker = String(localized: "its directory is damaged", bundle: .archiveKitStrings)
        } else if !overlapping.isEmpty {
            rewriteBlocker = String(localized: "some items share data, which is typical of a ZIP bomb", bundle: .archiveKitStrings)
        } else {
            rewriteBlocker = nil
        }
    }

    /// Opens the archive at `url` and reads its directory. Nothing is
    /// decompressed. Runs off the main actor.
    public static func open(_ url: URL, options: ZIPArchiveOptions = ZIPArchiveOptions()) async throws -> ZIPArchive {
        try Task.checkCancellation()
        let file = try RandomAccessFile(url: url)
        let started = ContinuousClock.now
        let directory: ParsedDirectory
        do {
            directory = try readCentralDirectory(file, options: options)
        } catch let error as ArchiveError {
            // A truncated download loses the directory at the end of the
            // file; recover what we can from the local headers instead.
            ArchiveLog.parsing.notice("Directory unreadable (\(error.logKind, privacy: .public)); scanning local headers")
            guard let recovered = try scanLocalHeaders(file, options: options), !recovered.entries.isEmpty else {
                ArchiveLog.parsing.error("Open failed: \(error.logKind, privacy: .public), \(file.size) bytes")
                throw error
            }
            ArchiveLog.parsing.notice("Recovered \(recovered.entries.count) items from local headers")
            directory = recovered
        }
        ArchiveLog.parsing.info("Opened \(directory.entries.count) items from \(file.size) bytes in \(started.duration(to: .now).formatted(.units(allowed: [.milliseconds], width: .narrow)), privacy: .public); \(directory.warnings.count) warnings")
        return ZIPArchive(url: url, options: options, file: file, directory: directory)
    }

    // MARK: Reading

    public func read(_ entry: ArchiveEntry, into consumer: (Data) throws -> Void) async throws {
        try await read(entry, password: password, into: consumer)
    }

    func read(_ entry: ArchiveEntry, password: [UInt8]?, into consumer: (Data) throws -> Void) async throws {
        guard entries.indices.contains(entry.id), entries[entry.id] == entry else {
            throw ArchiveError.unknownEntry(path: entry.path)
        }
        if entry.type == .directory { return }
        if entry.isEncrypted {
            guard entry.encryption?.isSupported == true else { throw ArchiveError.encryptedEntry(path: entry.path) }
            guard password != nil else { throw ArchiveError.passwordRequired(path: entry.path) }
        }
        guard entry.compressionMethod.isSupported else {
            throw ArchiveError.unsupportedCompressionMethod(path: entry.path, method: entry.compressionMethod)
        }
        try options.limits.check(entry)
        guard !overlappingEntryIDs.contains(entry.id) else {
            throw ArchiveError.malformed("“\(entry.path)” overlaps another item")
        }
        let overhead = entry.encryption?.overhead ?? 0
        guard entry.compressedSize >= overhead else {
            throw ArchiveError.corruptData(path: entry.path, reason: "its encryption header is cut off")
        }
        if entry.compressionMethod == .stored, entry.compressedSize - overhead != entry.uncompressedSize {
            throw ArchiveError.sizeMismatch(path: entry.path, expected: entry.uncompressedSize, actual: entry.compressedSize - overhead)
        }

        let header = try file.read(at: entry.storageOffset, count: ZIPHeaderParser.localHeaderSize)
        let dataStart = try ZIPHeaderParser.dataOffset(localHeader: header, headerOffset: entry.storageOffset)
        let (dataEnd, overflow) = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !overflow, dataEnd <= dataLimit else {
            throw ArchiveError.malformed("“\(entry.path)” extends beyond its allotted space")
        }

        let decryptor = try ZIPDecryptorFactory.make(for: entry, password: password ?? [])
        let decompressor = try ZIPDecompressorFactory.make(for: entry)
        var crc = CRC32()
        var produced: UInt64 = 0
        let emit: (Data) throws -> Void = { chunk in
            try Task.checkCancellation()
            produced += UInt64(chunk.count)
            // Never trust the stream over the directory: stop as soon as it
            // produces more than was declared.
            guard produced <= entry.uncompressedSize else {
                throw ArchiveError.sizeMismatch(path: entry.path, expected: entry.uncompressedSize, actual: produced)
            }
            crc.update(chunk)
            try consumer(chunk)
        }

        var offset = dataStart
        repeat {
            try Task.checkCancellation()
            let count = Int(min(UInt64(Self.readChunkSize), dataEnd - offset))
            let chunk = try file.read(at: offset, count: count)
            offset += UInt64(count)
            let isFinal = offset == dataEnd
            let plain = try decryptor?.process(chunk, isFinal: isFinal) ?? chunk
            try decompressor.process(plain, isFinal: isFinal, output: emit)
        } while offset < dataEnd

        guard produced == entry.uncompressedSize else {
            throw ArchiveError.sizeMismatch(path: entry.path, expected: entry.uncompressedSize, actual: produced)
        }
        if let expected = entry.crc32, crc.value != expected {
            throw ArchiveError.checksumMismatch(path: entry.path, expected: expected, actual: crc.value)
        }
    }

    // MARK: Opening

    struct ParsedDirectory {
        var entries: [ArchiveEntry]
        var records: [Data]?
        var comment = Data()
        var warnings: [String]
        var dataLimit: UInt64
        var detectedEncoding: FilenameEncoding? = nil
    }

    private static func readCentralDirectory(_ file: RandomAccessFile, options: ZIPArchiveOptions) throws -> ParsedDirectory {
        let eocd = try ZIPEndOfCentralDirectory.locate(in: file)
        guard eocd.centralDirectorySize <= eocd.directoryEnd else {
            throw ArchiveError.malformed("the directory is larger than the archive")
        }

        // Normally the directory sits at its stated offset. Self-extracting
        // archives prepend a stub without updating offsets; the directory
        // then ends where the EOCD begins, which reveals the shift.
        var baseOffset: UInt64 = 0
        if eocd.centralDirectorySize > 0 {
            let statedEnd = eocd.centralDirectoryOffset.addingReportingOverflow(eocd.centralDirectorySize)
            let atStatedOffset = !statedEnd.overflow && statedEnd.partialValue <= eocd.directoryEnd
                && hasCentralDirectorySignature(file, at: eocd.centralDirectoryOffset)
            if !atStatedOffset {
                let actualStart = eocd.directoryEnd - eocd.centralDirectorySize
                guard actualStart > eocd.centralDirectoryOffset,
                      hasCentralDirectorySignature(file, at: actualStart)
                else {
                    throw ArchiveError.malformed("the directory is not where the archive says it is")
                }
                baseOffset = actualStart - eocd.centralDirectoryOffset
            }
        }

        let directoryStart = eocd.centralDirectoryOffset + baseOffset
        let bytes = try file.read(at: directoryStart, count: Int(eocd.centralDirectorySize))
        let detected = options.filenameEncoding == .automatic
            ? FilenameEncodingDetector.detect(
                ZIPCentralDirectory.undeclaredNames(bytes, limit: FilenameEncodingDetector.sampleLimit)
            )
            : nil
        let result = ZIPCentralDirectory.parse(
            bytes,
            expectedCount: eocd.entryCount,
            baseOffset: baseOffset,
            encoding: options.filenameEncoding,
            detected: detected
        )
        return ParsedDirectory(
            entries: result.entries,
            records: result.records,
            comment: eocd.comment,
            warnings: result.warnings,
            dataLimit: directoryStart,
            detectedEncoding: detected
        )
    }

    private static func hasCentralDirectorySignature(_ file: RandomAccessFile, at offset: UInt64) -> Bool {
        guard let bytes = try? file.read(at: offset, count: 4) else { return false }
        return [UInt8](bytes) == [0x50, 0x4B, 0x01, 0x02]
    }

    /// Recovers entries from a damaged archive by walking its local headers
    /// from the start. Stops at the first entry whose size cannot be known
    /// without decompressing it, or which is cut off. Returns nil if the
    /// file does not start with a local header.
    private static func scanLocalHeaders(_ file: RandomAccessFile, options: ZIPArchiveOptions) throws -> ParsedDirectory? {
        var offset: UInt64 = 0
        var entries: [ArchiveEntry] = []
        var stopReason = String(localized: "the rest of the file is damaged", bundle: .archiveKitStrings)

        while offset + UInt64(ZIPHeaderParser.localHeaderSize) <= file.size {
            var reader = BinaryReader(try file.read(at: offset, count: ZIPHeaderParser.localHeaderSize))
            guard try reader.readUInt32() == ZIPSignature.localFileHeader else { break }
            _ = try reader.readUInt16() // version needed
            let flags = try reader.readUInt16()
            let rawMethod = try reader.readUInt16()
            let dosTime = try reader.readUInt16()
            let dosDate = try reader.readUInt16()
            let crc = try reader.readUInt32()
            var compressedSize = UInt64(try reader.readUInt32())
            var uncompressedSize = UInt64(try reader.readUInt32())
            let nameLength = Int(try reader.readUInt16())
            let extraLength = Int(try reader.readUInt16())

            let variableStart = offset + UInt64(ZIPHeaderParser.localHeaderSize)
            guard let variable = try? file.read(at: variableStart, count: nameLength + extraLength) else {
                stopReason = String(localized: "the last item is cut off", bundle: .archiveKitStrings)
                break
            }
            let rawName = [UInt8](variable.prefix(nameLength))
            let extra = ZIPHeaderParser.parseExtraFields([UInt8](variable.dropFirst(nameLength)))

            if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF, let field = extra[ZIPExtraFieldID.zip64] {
                var zip64 = BinaryReader(field)
                if let u = try? zip64.readUInt64(), let c = try? zip64.readUInt64() {
                    uncompressedSize = u
                    compressedSize = c
                }
            }
            let hasDataDescriptor = flags & 0x0008 != 0
            if hasDataDescriptor && compressedSize == 0 && rawName.last != UInt8(ascii: "/") {
                stopReason = String(localized: "an item’s size is only recorded after its data", bundle: .archiveKitStrings)
                break
            }

            let dataStart = variableStart + UInt64(nameLength + extraLength)
            let (dataEnd, overflow) = dataStart.addingReportingOverflow(compressedSize)
            guard !overflow, dataEnd <= file.size else {
                stopReason = String(localized: "the last item is cut off", bundle: .archiveKitStrings)
                break
            }

            var path = ZIPFilenameDecoder.decode(
                raw: rawName,
                isUTF8Flagged: flags & 0x0800 != 0,
                unicodePathExtra: extra[ZIPExtraFieldID.unicodePath],
                fallback: options.filenameEncoding
            ).replacingOccurrences(of: "\\", with: "/")
            let isDirectory = path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }

            var encryption = ZIPCentralDirectory.encryption(
                flags: flags, rawMethod: rawMethod, crc: crc, dosTime: dosTime, extra: extra
            )
            if rawMethod == 99, encryption == nil { encryption = .unsupported }
            var method = ZIPCentralDirectory.compressionMethod(rawMethod)
            if rawMethod == 99, let aes = extra[ZIPExtraFieldID.aes], aes.count >= 7 {
                method = ZIPCentralDirectory.compressionMethod(UInt16(aes[5]) | UInt16(aes[6]) << 8)
            }
            var recordedCRC: UInt32? = hasDataDescriptor && crc == 0 ? nil : crc
            if case .winZipAES(_, 2)? = encryption { recordedCRC = nil }

            entries.append(ArchiveEntry(
                id: entries.count,
                path: path,
                type: isDirectory ? .directory : .file,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                modificationDate: ZIPHeaderParser.modificationDate(extraFields: extra)
                    ?? ZIPHeaderParser.dosDate(date: dosDate, time: dosTime),
                compressionMethod: method,
                crc32: recordedCRC,
                isEncrypted: flags & 0x0001 != 0 || rawMethod == 99,
                encryption: encryption,
                storageOffset: offset
            ))

            offset = dataEnd
            if hasDataDescriptor {
                // Optional signature, CRC, then 32- or 64-bit sizes.
                let signature = (try? file.read(at: offset, count: 4)).map { [UInt8]($0) }
                offset += signature == [0x50, 0x4B, 0x07, 0x08] ? 4 : 0
                offset += compressedSize > 0xFFFF_FFFF || uncompressedSize > 0xFFFF_FFFF ? 20 : 12
            }
        }

        guard offset > 0 else { return nil }
        let warning = String(localized: "The archive’s directory is missing or damaged. \(entries.count) items were recovered, but \(stopReason).", bundle: .archiveKitStrings)
        return ParsedDirectory(entries: entries, records: nil, warnings: [warning], dataLimit: file.size)
    }

    /// Every entry's data begins at least 30 bytes (one local header) after
    /// its offset, so any two entries closer than that plus the first one's
    /// compressed size share bytes.
    private static func findOverlappingEntries(_ entries: [ArchiveEntry]) -> Set<Int> {
        let sorted = entries.sorted { $0.storageOffset < $1.storageOffset }
        var overlapping = Set<Int>()
        for (current, next) in zip(sorted, sorted.dropFirst()) {
            // Both additions are checked: a ZIP64 size can be close to
            // UInt64.max, and adding the header length to it would trap.
            let (headerEnd, headerOverflow) = current.storageOffset
                .addingReportingOverflow(UInt64(ZIPHeaderParser.localHeaderSize))
            let (minimumEnd, dataOverflow) = headerEnd.addingReportingOverflow(current.compressedSize)
            if headerOverflow || dataOverflow || minimumEnd > next.storageOffset {
                overlapping.insert(current.id)
                overlapping.insert(next.id)
            }
        }
        return overlapping
    }
}
