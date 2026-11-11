import Foundation

/// One 512-byte tar header block (POSIX ustar, GNU and the old v7 layout).
struct TarHeader {
    var name: String
    var mode: UInt16
    var size: UInt64
    var modificationTime: TimeInterval
    var typeFlag: UInt8
    var linkName: String
    var isUstar: Bool
    var isGNU: Bool

    static let blockSize = 512

    /// Whether `bytes` start with a valid header: the checksum matches. A
    /// tar archive has no signature before offset 257, so this is how a
    /// file is told to be one.
    static func looksLikeHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= blockSize, bytes[0] != 0 else { return false }
        return checksumIsValid(bytes)
    }

    static func checksumIsValid(_ block: [UInt8]) -> Bool {
        guard let stored = number(block, 148, 8) else { return false }
        var unsigned: UInt64 = 0
        var signed: Int64 = 0
        for (index, byte) in block[0..<blockSize].enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += UInt64(value)
            signed += Int64(Int8(bitPattern: value))
        }
        return stored == unsigned || Int64(bitPattern: stored) == signed
    }

    /// Parses a header, or returns nil if `block` is all zeros (the end of
    /// the archive). Throws if the checksum does not match.
    static func parse(_ block: [UInt8]) throws -> TarHeader? {
        precondition(block.count == blockSize)
        if block.allSatisfy({ $0 == 0 }) { return nil }
        guard checksumIsValid(block) else { throw ArchiveError.malformed("a tar header is damaged") }

        let magic = Array(block[257..<263])
        let isUstar = magic == Array("ustar\0".utf8)
        let isGNU = magic == Array("ustar ".utf8)
        var name = string(block, 0, 100)
        // The ustar prefix extends the name; GNU tar uses those bytes for other things.
        if isUstar {
            let prefix = string(block, 345, 155)
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        return TarHeader(
            name: name,
            mode: UInt16(truncatingIfNeeded: (number(block, 100, 8) ?? 0) & 0o7777),
            size: number(block, 124, 12) ?? 0,
            modificationTime: TimeInterval(number(block, 136, 12) ?? 0),
            typeFlag: block[156],
            linkName: string(block, 157, 100),
            isUstar: isUstar,
            isGNU: isGNU
        )
    }

    /// A NUL-terminated field. Names are UTF-8 in practice (pax says so);
    /// anything else is read as Latin-1 rather than refused.
    static func string(_ block: [UInt8], _ offset: Int, _ length: Int) -> String {
        decode(Array(block[offset..<(offset + length)].prefix { $0 != 0 }))
    }

    static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// An octal field, or GNU's base-256 form for values too big for octal.
    static func number(_ block: [UInt8], _ offset: Int, _ length: Int) -> UInt64? {
        let field = block[offset..<(offset + length)]
        if let first = field.first, first & 0x80 != 0 {
            guard first != 0xFF else { return nil }   // negative
            var value = UInt64(first & 0x7F)
            for byte in field.dropFirst() {
                let (shifted, overflow) = value.multipliedReportingOverflow(by: 256)
                guard !overflow else { return nil }
                value = shifted + UInt64(byte)
            }
            return value
        }
        var value: UInt64 = 0
        var digits = 0
        for byte in field.drop(while: { $0 == 0x20 || $0 == 0 }) {
            if byte == 0 || byte == 0x20 { break }
            guard (0x30...0x37).contains(byte) else { return nil }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 8)
            guard !overflow else { return nil }
            value = shifted + UInt64(byte - 0x30)
            digits += 1
        }
        return digits == 0 ? 0 : value
    }
}

/// An entry as the tar format describes it, before it becomes an `ArchiveEntry`.
struct TarRecord {
    var path: String
    var type: EntryType
    /// Bytes of data stored for it.
    var size: UInt64
    var mode: UInt16
    var modificationDate: Date?
    var linkTarget: String?
    var isHardLink = false
    var isSparse = false
    var realSize: UInt64?
    var dataOffset: UInt64 = 0
}

/// Turns header blocks into records, applying GNU long names and pax
/// extended headers (POSIX.1-2001) to the entry that follows them.
/// Independent of where the bytes come from, so the same logic reads a
/// seekable file and a decompressing stream.
struct TarIndexer {
    enum Next {
        /// A zero block: the end of the archive.
        case end
        /// A header whose data (this many bytes) holds long names or pax
        /// records: read it and pass it to `metadata`.
        case metadata(kind: UInt8, size: Int)
        /// An entry with `dataSize` bytes of data; call `commit` once its
        /// location is known.
        case entry(dataSize: UInt64)
        /// Something not listed (a device, pipe or label) with this much data to skip.
        case skip(dataSize: UInt64)
    }

    private(set) var records: [TarRecord] = []
    private(set) var skippedSpecialFiles = 0
    private(set) var hasSparseFiles = false

    private var longName: String?
    private var longLink: String?
    private var pax: [String: String] = [:]
    private var globalPax: [String: String] = [:]
    private var current: TarRecord?

    /// Metadata blocks this large are not read: a legitimate one is tiny.
    static let metadataLimit = 1 << 20

    mutating func header(_ block: [UInt8]) throws -> Next {
        guard let header = try TarHeader.parse(block) else { return .end }
        switch header.typeFlag {
        case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"), UInt8(ascii: "X"), UInt8(ascii: "g"):
            guard header.size <= UInt64(Self.metadataLimit) else {
                throw ArchiveError.malformed("a tar header block is implausibly large")
            }
            return .metadata(kind: header.typeFlag, size: Int(header.size))
        default:
            break
        }

        let settings = globalPax.merging(pax) { _, local in local }
        defer {
            longName = nil
            longLink = nil
            pax = [:]
        }

        var path = longName ?? settings["path"] ?? header.name
        var link = longLink ?? settings["linkpath"] ?? header.linkName
        var size = settings["size"].flatMap(UInt64.init) ?? header.size
        var mtime = header.modificationTime
        if let value = settings["mtime"].flatMap(Double.init) { mtime = value }

        var type: EntryType
        var isHardLink = false
        var isSparse = false
        var realSize: UInt64?
        switch header.typeFlag {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            type = .file
            if path.hasSuffix("/") { type = .directory }
        case UInt8(ascii: "S"):
            type = .file
            isSparse = true
        case UInt8(ascii: "5"):
            type = .directory
        case UInt8(ascii: "2"):
            type = .symlink
        case UInt8(ascii: "1"):
            type = .file
            isHardLink = true
        default:
            // Devices, pipes, labels, multi-volume pieces.
            skippedSpecialFiles += 1
            current = nil
            return .skip(dataSize: header.size)
        }
        if settings.keys.contains(where: { $0.hasPrefix("GNU.sparse.") }) {
            isSparse = true
            realSize = settings["GNU.sparse.realsize"].flatMap(UInt64.init) ?? settings["GNU.sparse.size"].flatMap(UInt64.init)
            if let name = settings["GNU.sparse.name"] { path = name }
        }
        hasSparseFiles = hasSparseFiles || isSparse

        // Directories, links and symlinks carry no data, whatever the size field says.
        let dataSize: UInt64
        switch type {
        case .directory, .symlink: dataSize = 0
        case .file: dataSize = isHardLink ? 0 : size
        }
        if type != .file { size = 0 }

        path = Self.normalised(path)
        if isHardLink { link = Self.normalised(link) }
        guard !path.isEmpty else {
            // "./" itself.
            current = nil
            return .skip(dataSize: dataSize)
        }
        current = TarRecord(
            path: path,
            type: type,
            size: size,
            mode: header.mode,
            modificationDate: mtime > 0 ? plausibleDate(secondsSince1970: mtime) : nil,
            linkTarget: type == .symlink || isHardLink ? link : nil,
            isHardLink: isHardLink,
            isSparse: isSparse,
            realSize: realSize
        )
        return .entry(dataSize: dataSize)
    }

    /// Applies the data of a long-name or pax header.
    mutating func metadata(kind: UInt8, data: [UInt8]) {
        switch kind {
        case UInt8(ascii: "L"): longName = TarHeader.decode(Array(data.prefix { $0 != 0 }))
        case UInt8(ascii: "K"): longLink = TarHeader.decode(Array(data.prefix { $0 != 0 }))
        case UInt8(ascii: "g"): globalPax.merge(Self.paxRecords(data)) { _, new in new }
        default: pax.merge(Self.paxRecords(data)) { _, new in new }
        }
    }

    /// Records the entry started by the last `.entry`, with its data at `dataOffset`.
    mutating func commit(dataOffset: UInt64) {
        guard var record = current else { return }
        record.dataOffset = dataOffset
        records.append(record)
        current = nil
    }

    /// Drops the entry started by the last `.entry` (when its data cannot be kept).
    mutating func discard() { current = nil }

    /// The last entry's data was cut short: keep what there is.
    mutating func truncateLast(to size: UInt64) {
        guard var last = records.popLast() else { return }
        last.size = size
        records.append(last)
    }

    /// `./a/b/` → `a/b`: how names are shown. A leading `/` is kept, so the
    /// safety checks see it.
    static func normalised(_ path: String) -> String {
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasSuffix("/") && result.count > 1 { result.removeLast() }
        return result == "." ? "" : result
    }

    /// pax records: `<length> <key>=<value>\n`, the length counting itself.
    static func paxRecords(_ data: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var position = 0
        while position < data.count {
            guard let space = data[position...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: data[position..<space], as: UTF8.self)),
                  length > space - position, length <= data.count - position
            else { break }
            let body = data[(space + 1)..<(position + length)]
            let text = String(decoding: body.dropLast(body.last == 0x0A ? 1 : 0), as: UTF8.self)
            if let equals = text.firstIndex(of: "=") {
                result[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
            position += length
        }
        return result
    }
}
