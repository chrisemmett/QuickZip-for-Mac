import Foundation

/// Parses central directory file headers (APPNOTE 4.3.12) into entries.
///
/// Parsing never decompresses anything; it reads only the directory, which
/// is why opening even very large archives is fast (HLD §6).
enum ZIPCentralDirectory {
    static let headerSize = 46

    struct Result {
        var entries: [ArchiveEntry]
        /// Each entry's complete directory record, byte for byte, so that a
        /// rewrite can keep everything about it (`ZIPRewriter`).
        var records: [Data]
        var warnings: [String]
    }

    /// Parses `count` records from `bytes`. Parsing stops at the first damaged
    /// record and returns everything recovered before it, with a warning,
    /// rather than refusing to open the archive (HLD §18.1).
    ///
    /// `baseOffset` is added to every local header offset to correct for
    /// data prepended to the archive. `detected` is the legacy encoding
    /// found by `FilenameEncodingDetector`, used for names that are not
    /// UTF-8 when `encoding` is `.automatic`.
    static func parse(
        _ bytes: Data,
        expectedCount: UInt64,
        baseOffset: UInt64,
        encoding: FilenameEncoding,
        detected: FilenameEncoding? = nil
    ) -> Result {
        var reader = BinaryReader(bytes)
        var entries: [ArchiveEntry] = []
        var records: [Data] = []
        var warnings: [String] = []
        entries.reserveCapacity(Int(clamping: min(expectedCount, UInt64(bytes.count / headerSize))))

        while UInt64(entries.count) < expectedCount || reader.remaining >= headerSize {
            if reader.remaining < 4 {
                break
            }
            let start = reader.offset
            do {
                let entry = try parseRecord(&reader, id: entries.count, baseOffset: baseOffset, encoding: encoding, detected: detected)
                entries.append(entry)
                let recordStart = bytes.startIndex + start
                records.append(Data(bytes[recordStart..<recordStart + (reader.offset - start)]))
            } catch {
                // A record without a valid signature where the count says
                // there should be none left is just trailing padding.
                if UInt64(entries.count) >= expectedCount { break }
                let reason = (error as? ArchiveError).flatMap(\.errorDescription) ?? "\(error)"
                warnings.append(String(localized: "The archive’s directory is damaged at byte \(start); only \(entries.count) of \(expectedCount) items could be read. (\(reason))", bundle: .archiveKitStrings))
                return Result(entries: entries, records: records, warnings: warnings)
            }
        }

        if UInt64(entries.count) != expectedCount {
            warnings.append(String(localized: "The archive declares \(expectedCount) items but its directory contains \(entries.count).", bundle: .archiveKitStrings))
        }
        return Result(entries: entries, records: records, warnings: warnings)
    }

    private static func parseRecord(
        _ reader: inout BinaryReader,
        id: Int,
        baseOffset: UInt64,
        encoding: FilenameEncoding,
        detected: FilenameEncoding?
    ) throws -> ArchiveEntry {
        guard try reader.readUInt32() == ZIPSignature.centralDirectoryHeader else {
            throw ArchiveError.malformed("an item in the directory has an invalid signature")
        }
        let versionMadeBy = try reader.readUInt16()
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
        let commentLength = Int(try reader.readUInt16())
        let diskStart = try reader.readUInt16()
        _ = try reader.readUInt16() // internal attributes
        let externalAttributes = try reader.readUInt32()
        var localHeaderOffset = UInt64(try reader.readUInt32())
        let rawName = try reader.readBytes(nameLength)
        let extra = ZIPHeaderParser.parseExtraFields(try reader.readBytes(extraLength))
        try reader.skip(commentLength)

        // ZIP64 extended information: only the fields whose 32-bit value is
        // saturated are present, in this fixed order (APPNOTE 4.5.3).
        if uncompressedSize == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF
            || localHeaderOffset == 0xFFFF_FFFF || diskStart == 0xFFFF {
            guard let field = extra[ZIPExtraFieldID.zip64] else {
                throw ArchiveError.malformed("an item needs ZIP64 information that is missing")
            }
            var zip64 = BinaryReader(field)
            if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try zip64.readUInt64() }
            if compressedSize == 0xFFFF_FFFF { compressedSize = try zip64.readUInt64() }
            if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try zip64.readUInt64() }
        }

        let (absoluteOffset, overflow) = localHeaderOffset.addingReportingOverflow(baseOffset)
        guard !overflow else { throw ArchiveError.malformed("an item's offset is out of range") }

        let isEncrypted = flags & 0x0001 != 0
        var method = compressionMethod(rawMethod)
        var encryption = Self.encryption(flags: flags, rawMethod: rawMethod, crc: crc, dosTime: dosTime, extra: extra)
        // WinZip AES stores the real method in its extra field (method 99).
        if rawMethod == 99, let aes = extra[ZIPExtraFieldID.aes], aes.count >= 7 {
            method = compressionMethod(UInt16(aes[5]) | UInt16(aes[6]) << 8)
        }
        // AE-2 has no CRC-32: the authentication code vouches for the data.
        var storedCRC: UInt32? = crc
        if case .winZipAES(_, 2)? = encryption { storedCRC = nil }
        if rawMethod == 99, encryption == nil { encryption = .unsupported }

        var path = ZIPFilenameDecoder.decode(
            raw: rawName,
            isUTF8Flagged: flags & 0x0800 != 0,
            unicodePathExtra: extra[ZIPExtraFieldID.unicodePath],
            fallback: encoding,
            detected: detected
        )
        path = path.replacingOccurrences(of: "\\", with: "/")
        let hasTrailingSlash = path.hasSuffix("/")
        while path.hasSuffix("/") { path.removeLast() }

        // Unix hosts (3) and macOS (19) keep st_mode in the high 16 bits.
        let host = versionMadeBy >> 8
        let mode: UInt16? = (host == 3 || host == 19) && externalAttributes >> 16 != 0
            ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil
        let type: EntryType
        switch mode.map({ $0 & 0o170000 }) {
        case 0o120000?: type = .symlink
        case 0o040000?: type = .directory
        default:
            let isDOSDirectory = externalAttributes & 0x10 != 0 && host == 0
            type = hasTrailingSlash || isDOSDirectory ? .directory : .file
        }

        let date = ZIPHeaderParser.modificationDate(extraFields: extra)
            ?? ZIPHeaderParser.dosDate(date: dosDate, time: dosTime)

        return ArchiveEntry(
            id: id,
            path: path,
            type: type,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            modificationDate: date,
            compressionMethod: method,
            crc32: storedCRC,
            isEncrypted: isEncrypted || rawMethod == 99,
            encryption: encryption,
            posixPermissions: mode.map { $0 & 0o7777 },
            storageOffset: absoluteOffset
        )
    }

    /// Raw names, up to `limit`, whose encoding the archive leaves open:
    /// non-ASCII names without the UTF-8 flag or an Info-ZIP Unicode Path
    /// field. Stops quietly at the first damaged record; `parse` reports
    /// the damage.
    static func undeclaredNames(_ bytes: Data, limit: Int) -> [[UInt8]] {
        var reader = BinaryReader(bytes)
        var names: [[UInt8]] = []
        while names.count < limit, reader.remaining >= headerSize {
            guard (try? reader.readUInt32()) == ZIPSignature.centralDirectoryHeader,
                  (try? reader.skip(4)) != nil,
                  let flags = try? reader.readUInt16(),
                  (try? reader.skip(18)) != nil,
                  let nameLength = try? reader.readUInt16(),
                  let extraLength = try? reader.readUInt16(),
                  let commentLength = try? reader.readUInt16(),
                  (try? reader.skip(12)) != nil,
                  let name = try? reader.readBytes(Int(nameLength)),
                  let extra = try? reader.readBytes(Int(extraLength)),
                  (try? reader.skip(Int(commentLength))) != nil
            else { break }
            if flags & 0x0800 == 0, name.contains(where: { $0 >= 0x80 }),
               ZIPHeaderParser.parseExtraFields(extra)[ZIPExtraFieldID.unicodePath] == nil {
                names.append(name)
            }
        }
        return names
    }

    /// The encryption an entry's flags and extra fields describe, or nil if
    /// it is not encrypted.
    static func encryption(
        flags: UInt16, rawMethod: UInt16, crc: UInt32, dosTime: UInt16, extra: [UInt16: [UInt8]]
    ) -> EntryEncryption? {
        if rawMethod == 99 {
            guard let aes = extra[ZIPExtraFieldID.aes], aes.count >= 7,
                  aes[2] == UInt8(ascii: "A"), aes[3] == UInt8(ascii: "E"),
                  let strength = AESStrength(rawValue: aes[4])
            else { return .unsupported }
            let version = Int(aes[0]) | Int(aes[1]) << 8
            guard version == 1 || version == 2 else { return .unsupported }
            return .winZipAES(strength: strength, version: version)
        }
        guard flags & 0x0001 != 0 else { return nil }
        // Strong encryption (bit 6) and masked directories (bit 13).
        if flags & 0x0040 != 0 || flags & 0x2000 != 0 { return .unsupported }
        // With a data descriptor the CRC is not known when the header is
        // written, so the check byte comes from the time instead.
        let check = flags & 0x0008 != 0 ? UInt8(truncatingIfNeeded: dosTime >> 8) : UInt8(truncatingIfNeeded: crc >> 24)
        return .zipCrypto(checkByte: check)
    }

    static func compressionMethod(_ raw: UInt16) -> CompressionMethod {
        switch raw {
        case 0: return .stored
        case 8: return .deflate
        case 9: return .deflate64
        case 12: return .bzip2
        case 14: return .lzma
        case 93: return .zstd
        case 95: return .xz
        case 98: return .ppmd
        default: return .other(raw)
        }
    }
}
