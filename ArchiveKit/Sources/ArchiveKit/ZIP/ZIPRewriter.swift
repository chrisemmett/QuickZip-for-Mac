import Foundation
#if canImport(Compression)
import Compression
#endif

extension ZIPArchive {
    /// Writes a modified copy of the archive (see `RewritableArchive`).
    ///
    /// Kept entries are copied byte for byte: local header, data and data
    /// descriptor, then their original directory record with only the
    /// offset changed. Added items are deflated (or stored, if that is
    /// smaller) with UTF-8 names, Unix permissions and timestamps. The
    /// result is reopened and checked before this returns.
    public func rewrite(
        to destination: URL,
        removing removed: Set<ArchiveEntry.ID>,
        adding additions: [ArchiveAddition]
    ) async throws {
        if let rewriteBlocker {
            throw ArchiveError.io("“\(url.lastPathComponent)” can’t be changed because \(rewriteBlocker).")
        }
        guard let directoryRecords else {
            throw ArchiveError.io("“\(url.lastPathComponent)” can’t be changed because its directory is missing.")
        }

        let kept = entries.filter { !removed.contains($0.id) }
        let items = try ZIPAdditionPlanner.plan(additions, keeping: kept.map(\.path))
        ArchiveLog.extraction.info("Rewriting archive: keeping \(kept.count) items, adding \(items.count), removing \(removed.count)")

        let output = try ZIPOutputFile(creating: destination)
        var records: [Data] = []
        records.reserveCapacity(kept.count + items.count)

        for entry in kept {
            try Task.checkCancellation()
            let range = try storedRange(of: entry)
            let newOffset = output.offset
            var position = range.lowerBound
            while position < range.upperBound {
                try Task.checkCancellation()
                let count = Int(min(UInt64(Self.copyChunkSize), range.upperBound - position))
                try output.write(try file.read(at: position, count: count))
                position += UInt64(count)
            }
            records.append(try ZIPRecordRelocator.relocate(directoryRecords[entry.id], to: newOffset))
        }
        for item in items {
            try Task.checkCancellation()
            records.append(try ZIPEntryWriter.write(item, to: output))
        }
        try output.finish(centralRecords: records, comment: comment)

        let check = try await ZIPArchive.open(destination, options: options)
        guard check.entries.count == records.count, check.rewriteBlocker == nil else {
            ArchiveLog.extraction.error("Rewritten archive failed verification")
            throw ArchiveError.io("The updated archive could not be verified, so the original was left unchanged.")
        }
        ArchiveLog.extraction.info("Rewrote archive: \(records.count) items")
    }

    static let copyChunkSize = 1 << 20

    /// The bytes that make up `entry` in this file: local header, data and
    /// any data descriptor.
    func storedRange(of entry: ArchiveEntry) throws -> Range<UInt64> {
        let start = entry.storageOffset
        var reader = BinaryReader(try file.read(at: start, count: ZIPHeaderParser.localHeaderSize))
        guard try reader.readUInt32() == ZIPSignature.localFileHeader else {
            throw ArchiveError.malformed("the local header of “\(entry.path)” is missing")
        }
        try reader.seek(to: 6)
        let flags = try reader.readUInt16()
        try reader.seek(to: 26)
        let nameLength = UInt64(try reader.readUInt16())
        let extraLength = UInt64(try reader.readUInt16())

        let extraStart = start + UInt64(ZIPHeaderParser.localHeaderSize) + nameLength
        let dataStart = extraStart + extraLength
        let (dataEnd, overflow) = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !overflow, dataEnd <= dataLimit else {
            throw ArchiveError.malformed("“\(entry.path)” extends beyond its allotted space")
        }

        var end = dataEnd
        if flags & 0x0008 != 0 {
            // Data descriptor: optional signature, CRC, then sizes that are
            // 64-bit when the entry uses ZIP64.
            let localExtra = ZIPHeaderParser.parseExtraFields([UInt8](try file.read(at: extraStart, count: Int(extraLength))))
            let isZIP64 = localExtra[ZIPExtraFieldID.zip64] != nil
                || entry.compressedSize >= 0xFFFF_FFFF || entry.uncompressedSize >= 0xFFFF_FFFF
            let signature = dataEnd + 4 <= dataLimit
                ? (try? file.read(at: dataEnd, count: 4)).map { [UInt8]($0) } : nil
            end += (signature == [0x50, 0x4B, 0x07, 0x08] ? 4 : 0) + 4 + (isZIP64 ? 16 : 8)
            guard end <= dataLimit else {
                throw ArchiveError.malformed("the data descriptor of “\(entry.path)” is cut off")
            }
        }
        return start..<end
    }
}

// MARK: - Planning additions

/// One file, folder or link to write, with its final archive path.
struct ZIPPlannedItem {
    enum Kind { case file, directory, symlink }

    let source: URL
    let path: String
    let kind: Kind
    let size: UInt64
    let modificationDate: Date
    let permissions: UInt16
}

enum ZIPAdditionPlanner {
    /// Expands folders into everything inside them and checks every path.
    /// Throws if an added path would duplicate a kept entry or another
    /// added item.
    static func plan(_ additions: [ArchiveAddition], keeping keptPaths: [String]) throws -> [ZIPPlannedItem] {
        var taken = Set(keptPaths)
        var items: [ZIPPlannedItem] = []

        func add(_ source: URL, path: String) throws {
            guard let item = try item(at: source, path: path) else { return }
            guard taken.insert(path).inserted else {
                throw ArchiveError.destinationExists(path)
            }
            items.append(item)
        }

        for addition in additions {
            let path = try validated(addition.path)
            try add(addition.source, path: path)
            guard items.last?.path == path, items.last?.kind == .directory else { continue }

            // Relative paths are taken from the resolved parent, so that
            // /tmp and /private/tmp agree, without resolving a link itself.
            let base = addition.source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard let enumerator = FileManager.default.enumerator(
                at: addition.source,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: nil
            ) else { continue }
            for case let child as URL in enumerator {
                if child.lastPathComponent == ".DS_Store" { continue }
                let parent = child.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
                guard parent.starts(with: base) else { continue }
                let relative = parent.dropFirst(base.count) + [child.lastPathComponent]
                try add(child, path: path + "/" + relative.joined(separator: "/"))
            }
        }
        return items
    }

    private static func validated(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ArchiveError.unsafePath(path) }
        return path
    }

    /// The item at `source`, without following a link there. Nil for
    /// things a ZIP cannot hold, such as sockets.
    private static func item(at source: URL, path: String) throws -> ZIPPlannedItem? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch {
            throw ArchiveError.io("“\(source.lastPathComponent)” could not be read: \(error.localizedDescription)")
        }
        let kind: ZIPPlannedItem.Kind
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?: kind = .file
        case .typeDirectory?: kind = .directory
        case .typeSymbolicLink?: kind = .symlink
        default: return nil
        }
        let defaultPermissions: UInt16 = kind == .file ? 0o644 : 0o755
        return ZIPPlannedItem(
            source: source,
            path: path,
            kind: kind,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date ?? Date(),
            permissions: (attributes[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) & 0o7777 }
                ?? defaultPermissions
        )
    }
}

// MARK: - Writing entries

enum ZIPEntryWriter {
    private static let readChunkSize = 1 << 20
    private static let versionMadeBy: UInt16 = 3 << 8 | 45 // Unix, ZIP 4.5
    private static let utf8Flag: UInt16 = 0x0800

    /// Writes `item`'s local header and data, and returns its directory
    /// record.
    static func write(_ item: ZIPPlannedItem, to output: ZIPOutputFile) throws -> Data {
        let name = Array((item.kind == .directory ? item.path + "/" : item.path).utf8)
        guard name.count <= 0xFFFF else { throw ArchiveError.unsafePath(item.path) }
        let (dosDate, dosTime) = dosDateTime(item.modificationDate)
        let timestamp = extendedTimestamp(item.modificationDate)
        // Sizes are only known afterwards; a file that could need ZIP64
        // reserves room for 64-bit sizes in its local header.
        let localZIP64 = item.kind == .file && item.size >= 0xFFFF_FFF0

        var method: UInt16 = 0
        #if canImport(Compression)
        if item.kind == .file && item.size > 0 { method = 8 }
        #endif

        let headerOffset = output.offset
        func localHeader(method: UInt16, crc: UInt32, compressed: UInt64, uncompressed: UInt64) -> [UInt8] {
            var header = ByteWriter()
            header.u32(ZIPSignature.localFileHeader)
            header.u16(localZIP64 ? 45 : 20)
            header.u16(utf8Flag)
            header.u16(method)
            header.u16(dosTime)
            header.u16(dosDate)
            header.u32(crc)
            header.u32(localZIP64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: compressed))
            header.u32(localZIP64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: uncompressed))
            var extra = timestamp
            if localZIP64 {
                extra.u16(ZIPExtraFieldID.zip64)
                extra.u16(16)
                extra.u64(uncompressed)
                extra.u64(compressed)
            }
            header.u16(UInt16(name.count))
            header.u16(UInt16(extra.bytes.count))
            header.append(name)
            header.append(extra.bytes)
            return header.bytes
        }

        try output.write(localHeader(method: method, crc: 0, compressed: 0, uncompressed: 0))
        let dataStart = output.offset
        var crc = CRC32()
        var uncompressed: UInt64 = 0

        switch item.kind {
        case .directory:
            break
        case .symlink:
            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: item.source.path)
            } catch {
                throw ArchiveError.io("The link “\(item.source.lastPathComponent)” could not be read: \(error.localizedDescription)")
            }
            let data = Data(target.utf8)
            crc.update(data)
            uncompressed = UInt64(data.count)
            try output.write(data)
        case .file:
            (crc, uncompressed) = try copyFile(item.source, method: method, to: output)
            // Already-compressed files often grow when deflated; store them.
            if method == 8 && output.offset - dataStart >= uncompressed {
                try output.truncate(to: dataStart)
                method = 0
                let stored = try copyFile(item.source, method: 0, to: output)
                guard stored.crc.value == crc.value, stored.count == uncompressed else {
                    throw ArchiveError.io("“\(item.source.lastPathComponent)” changed while it was being added.")
                }
            }
        }

        let compressed = output.offset - dataStart
        if !localZIP64 && (compressed >= 0xFFFF_FFFF || uncompressed >= 0xFFFF_FFFF) {
            throw ArchiveError.io("“\(item.source.lastPathComponent)” changed while it was being added.")
        }
        try output.patch(at: headerOffset, with: localHeader(method: method, crc: crc.value, compressed: compressed, uncompressed: uncompressed))

        // Directory record: 64-bit values go in a ZIP64 field only when
        // their 32-bit slot is saturated (APPNOTE 4.5.3).
        var zip64 = ByteWriter()
        if uncompressed >= 0xFFFF_FFFF { zip64.u64(uncompressed) }
        if compressed >= 0xFFFF_FFFF { zip64.u64(compressed) }
        if headerOffset >= 0xFFFF_FFFF { zip64.u64(headerOffset) }
        var extra = timestamp
        if !zip64.bytes.isEmpty {
            extra.u16(ZIPExtraFieldID.zip64)
            extra.u16(UInt16(zip64.bytes.count))
            extra.append(zip64.bytes)
        }

        let fileType: UInt32
        switch item.kind {
        case .file: fileType = 0o100000
        case .directory: fileType = 0o040000
        case .symlink: fileType = 0o120000
        }
        let mode = fileType | UInt32(item.permissions)

        var record = ByteWriter()
        record.u32(ZIPSignature.centralDirectoryHeader)
        record.u16(versionMadeBy)
        record.u16(zip64.bytes.isEmpty && !localZIP64 ? 20 : 45)
        record.u16(utf8Flag)
        record.u16(method)
        record.u16(dosTime)
        record.u16(dosDate)
        record.u32(crc.value)
        record.u32(saturated32(compressed))
        record.u32(saturated32(uncompressed))
        record.u16(UInt16(name.count))
        record.u16(UInt16(extra.bytes.count))
        record.u16(0) // comment length
        record.u16(0) // disk number
        record.u16(0) // internal attributes
        record.u32(mode << 16 | (item.kind == .directory ? 0x10 : 0))
        record.u32(saturated32(headerOffset))
        record.append(name)
        record.append(extra.bytes)
        return Data(record.bytes)
    }

    /// Streams a file into the archive, deflating it for method 8.
    private static func copyFile(_ source: URL, method: UInt16, to output: ZIPOutputFile) throws -> (crc: CRC32, count: UInt64) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source)
        } catch {
            throw ArchiveError.io("“\(source.lastPathComponent)” could not be read: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var crc = CRC32()
        var count: UInt64 = 0
        #if canImport(Compression)
        let encoder = method == 8 ? try DeflateEncoder() : nil
        #endif
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: readChunkSize) ?? Data()
            } catch {
                throw ArchiveError.io("“\(source.lastPathComponent)” could not be read: \(error.localizedDescription)")
            }
            crc.update(chunk)
            count += UInt64(chunk.count)
            #if canImport(Compression)
            if let encoder {
                try encoder.process(chunk, isFinal: chunk.isEmpty, output: output.write)
                if chunk.isEmpty { break }
                continue
            }
            #endif
            if chunk.isEmpty { break }
            try output.write(chunk)
        }
        return (crc, count)
    }

    private static func saturated32(_ value: UInt64) -> UInt32 {
        value >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(value)
    }

    /// MS-DOS date and time in local time, clamped to the range it can hold.
    static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, year >= 1980 else { return (date: 1 << 5 | 1, time: 0) }
        guard year <= 2107 else { return (date: 127 << 9 | 12 << 5 | 31, time: 23 << 11 | 59 << 5 | 29) }
        let dosDate = UInt16(year - 1980) << 9 | UInt16(c.month ?? 1) << 5 | UInt16(c.day ?? 1)
        let dosTime = UInt16(c.hour ?? 0) << 11 | UInt16(c.minute ?? 0) << 5 | UInt16((c.second ?? 0) / 2)
        return (dosDate, dosTime)
    }

    /// An Info-ZIP extended timestamp field holding the modification time.
    private static func extendedTimestamp(_ date: Date) -> ByteWriter {
        var field = ByteWriter()
        field.u16(ZIPExtraFieldID.extendedTimestamp)
        field.u16(5)
        field.u8(1) // modification time present
        let seconds = Int32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)))
        field.u32(UInt32(bitPattern: seconds))
        return field
    }
}

// MARK: - Relocating kept entries

enum ZIPRecordRelocator {
    /// Returns a copy of a directory record pointing at `offset`, adding,
    /// updating or removing its ZIP64 offset as needed. Everything else in
    /// the record is kept.
    static func relocate(_ record: Data, to offset: UInt64) throws -> Data {
        let bytes = [UInt8](record)
        var reader = BinaryReader(bytes)
        try reader.seek(to: 6)
        let versionNeeded = try reader.readUInt16()
        try reader.seek(to: 20)
        let compressed32 = try reader.readUInt32()
        let uncompressed32 = try reader.readUInt32()
        let nameLength = Int(try reader.readUInt16())
        let extraLength = Int(try reader.readUInt16())
        let commentLength = Int(try reader.readUInt16())
        let nameEnd = ZIPCentralDirectory.headerSize + nameLength
        let extraEnd = nameEnd + extraLength
        guard bytes.count == extraEnd + commentLength else {
            throw ArchiveError.malformed("a directory record has an unexpected length")
        }

        var fields: [(id: UInt16, data: [UInt8])] = []
        var extraReader = BinaryReader(Array(bytes[nameEnd..<extraEnd]))
        while extraReader.remaining >= 4 {
            guard let id = try? extraReader.readUInt16(),
                  let size = try? extraReader.readUInt16(),
                  let data = try? extraReader.readBytes(Int(size))
            else { break }
            fields.append((id, data))
        }

        // Keep the 64-bit sizes; the old offset and disk number go.
        let zip64Index = fields.firstIndex { $0.id == ZIPExtraFieldID.zip64 }
        var oldZIP64 = BinaryReader(zip64Index.map { fields[$0].data } ?? [])
        var zip64 = ByteWriter()
        if uncompressed32 == 0xFFFF_FFFF { zip64.u64(try oldZIP64.readUInt64()) }
        if compressed32 == 0xFFFF_FFFF { zip64.u64(try oldZIP64.readUInt64()) }
        let offset32: UInt32
        if offset >= 0xFFFF_FFFF {
            offset32 = 0xFFFF_FFFF
            zip64.u64(offset)
        } else {
            offset32 = UInt32(offset)
        }

        switch (zip64Index, zip64.bytes.isEmpty) {
        case (let index?, true): fields.remove(at: index)
        case (let index?, false): fields[index].data = zip64.bytes
        case (nil, false): fields.insert((ZIPExtraFieldID.zip64, zip64.bytes), at: 0)
        case (nil, true): break
        }
        var extra = ByteWriter()
        for field in fields {
            extra.u16(field.id)
            extra.u16(UInt16(field.data.count))
            extra.append(field.data)
        }
        guard extra.bytes.count <= 0xFFFF else {
            throw ArchiveError.malformed("a directory record's extra data is too long")
        }

        var result = ByteWriter()
        result.append(Array(bytes[0..<ZIPCentralDirectory.headerSize]))
        result.set16(30, UInt16(extra.bytes.count))
        result.set16(34, 0) // disk number
        result.set32(42, offset32)
        if !zip64.bytes.isEmpty && versionNeeded & 0xFF < 45 {
            result.set16(6, versionNeeded & 0xFF00 | 45)
        }
        result.append(Array(bytes[ZIPCentralDirectory.headerSize..<nameEnd]))
        result.append(extra.bytes)
        result.append(Array(bytes[extraEnd...]))
        return Data(result.bytes)
    }
}

// MARK: - Output

/// The archive being written: sequential writes, plus patching headers once
/// sizes are known.
final class ZIPOutputFile {
    let url: URL
    private let handle: FileHandle
    private(set) var offset: UInt64 = 0

    init(creating url: URL) throws {
        self.url = url
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil)
        else {
            throw ArchiveError.io("“\(url.lastPathComponent)” could not be created.")
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw ArchiveError.io("“\(url.lastPathComponent)” could not be opened for writing: \(error.localizedDescription)")
        }
    }

    deinit {
        try? handle.close()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ArchiveError.io("The archive could not be written: \(error.localizedDescription)")
        }
        offset += UInt64(data.count)
    }

    func write(_ bytes: [UInt8]) throws {
        try write(Data(bytes))
    }

    /// Overwrites earlier bytes without moving the end of the file.
    func patch(at position: UInt64, with bytes: [UInt8]) throws {
        precondition(position + UInt64(bytes.count) <= offset)
        do {
            try handle.seek(toOffset: position)
            try handle.write(contentsOf: Data(bytes))
            try handle.seek(toOffset: offset)
        } catch {
            throw ArchiveError.io("The archive could not be written: \(error.localizedDescription)")
        }
    }

    func truncate(to position: UInt64) throws {
        do {
            try handle.truncate(atOffset: position)
            try handle.seek(toOffset: position)
        } catch {
            throw ArchiveError.io("The archive could not be written: \(error.localizedDescription)")
        }
        offset = position
    }

    /// Writes the central directory and end records, with ZIP64 versions
    /// when the counts or offsets need them, and flushes the file.
    func finish(centralRecords: [Data], comment: Data) throws {
        let directoryOffset = offset
        for record in centralRecords {
            try write(record)
        }
        let directorySize = offset - directoryOffset
        let count = UInt64(centralRecords.count)

        if count >= 0xFFFF || directoryOffset >= 0xFFFF_FFFF || directorySize >= 0xFFFF_FFFF {
            let recordOffset = offset
            var zip64 = ByteWriter()
            zip64.u32(ZIPSignature.zip64EndOfCentralDirectory)
            zip64.u64(44) // size of the rest of the record
            zip64.u16(3 << 8 | 45)
            zip64.u16(45)
            zip64.u32(0) // this disk
            zip64.u32(0) // disk with the directory
            zip64.u64(count)
            zip64.u64(count)
            zip64.u64(directorySize)
            zip64.u64(directoryOffset)
            zip64.u32(ZIPSignature.zip64EndOfCentralDirectoryLocator)
            zip64.u32(0) // disk with the ZIP64 record
            zip64.u64(recordOffset)
            zip64.u32(1) // total disks
            try write(zip64.bytes)
        }

        let commentBytes = [UInt8](comment.prefix(0xFFFF))
        var end = ByteWriter()
        end.u32(ZIPSignature.endOfCentralDirectory)
        end.u16(0) // this disk
        end.u16(0) // disk with the directory
        end.u16(UInt16(min(count, 0xFFFF)))
        end.u16(UInt16(min(count, 0xFFFF)))
        end.u32(UInt32(min(directorySize, 0xFFFF_FFFF)))
        end.u32(UInt32(min(directoryOffset, 0xFFFF_FFFF)))
        end.u16(UInt16(commentBytes.count))
        end.append(commentBytes)
        try write(end.bytes)

        do {
            try handle.synchronize()
        } catch {
            throw ArchiveError.io("The archive could not be written: \(error.localizedDescription)")
        }
    }
}

/// Builds little-endian structures.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { append(withUnsafeBytes(of: value.littleEndian, Array.init)) }
    mutating func u32(_ value: UInt32) { append(withUnsafeBytes(of: value.littleEndian, Array.init)) }
    mutating func u64(_ value: UInt64) { append(withUnsafeBytes(of: value.littleEndian, Array.init)) }
    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }

    mutating func set16(_ position: Int, _ value: UInt16) {
        bytes.replaceSubrange(position..<position + 2, with: withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    mutating func set32(_ position: Int, _ value: UInt32) {
        bytes.replaceSubrange(position..<position + 4, with: withUnsafeBytes(of: value.littleEndian, Array.init))
    }
}

#if canImport(Compression)

/// Raw DEFLATE (RFC 1951) via Compression.framework, the encoding ZIP's
/// method 8 stores.
final class DeflateEncoder {
    private static let outputCapacity = 64 * 1024

    private let stream: UnsafeMutablePointer<compression_stream>
    private let outputBuffer: UnsafeMutablePointer<UInt8>

    init() throws {
        stream = .allocate(capacity: 1)
        outputBuffer = .allocate(capacity: Self.outputCapacity)
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            outputBuffer.deallocate()
            throw ArchiveError.io("Could not initialise the compressor.")
        }
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        outputBuffer.deallocate()
    }

    /// Compresses `input`; `isFinal` flushes and ends the stream.
    func process(_ input: Data, isFinal: Bool, output: (Data) throws -> Void) throws {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var placeholder: UInt8 = 0
            try withUnsafePointer(to: &placeholder) { emptyInput in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? emptyInput
                stream.pointee.src_size = raw.count
                let flags = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                while true {
                    stream.pointee.dst_ptr = outputBuffer
                    stream.pointee.dst_size = Self.outputCapacity
                    let status = compression_stream_process(stream, flags)
                    guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END else {
                        throw ArchiveError.io("The data could not be compressed.")
                    }
                    let produced = Self.outputCapacity - stream.pointee.dst_size
                    if produced > 0 {
                        try output(Data(bytes: outputBuffer, count: produced))
                    }
                    if status == COMPRESSION_STATUS_END { break }
                    // Without finalising, stop once the input is consumed
                    // and the encoder has room to spare.
                    if !isFinal && stream.pointee.src_size == 0 && stream.pointee.dst_size > 0 { break }
                }
            }
        }
    }
}

#endif
