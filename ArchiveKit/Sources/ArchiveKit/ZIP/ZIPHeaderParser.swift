import Foundation

/// ZIP signatures and the shared helpers for parsing headers (APPNOTE 4.3).
enum ZIPSignature {
    static let localFileHeader: UInt32 = 0x0403_4B50
    static let centralDirectoryHeader: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4B50
    static let zip64EndOfCentralDirectoryLocator: UInt32 = 0x0706_4B50
}

enum ZIPExtraFieldID {
    static let zip64: UInt16 = 0x0001
    static let ntfs: UInt16 = 0x000A
    static let extendedTimestamp: UInt16 = 0x5455
    static let unicodePath: UInt16 = 0x7075
    static let aes: UInt16 = 0x9901
}

enum ZIPHeaderParser {
    /// Size of the fixed part of a local file header.
    static let localHeaderSize = 30

    /// Parses an extra field block into `[id: data]`. A malformed trailing
    /// field is ignored rather than failing the whole entry, as other tools do.
    static func parseExtraFields(_ bytes: [UInt8]) -> [UInt16: [UInt8]] {
        var fields: [UInt16: [UInt8]] = [:]
        var reader = BinaryReader(bytes)
        while reader.remaining >= 4 {
            guard let id = try? reader.readUInt16(),
                  let size = try? reader.readUInt16(),
                  let data = try? reader.readBytes(Int(size))
            else { break }
            if fields[id] == nil { fields[id] = data }
        }
        return fields
    }

    /// Returns the offset of an entry's compressed data, given the bytes of
    /// its fixed-size local file header (APPNOTE 4.3.7).
    static func dataOffset(localHeader bytes: Data, headerOffset: UInt64) throws -> UInt64 {
        var reader = BinaryReader(bytes)
        guard try reader.readUInt32() == ZIPSignature.localFileHeader else {
            throw ArchiveError.malformed("an entry's local header is missing")
        }
        try reader.seek(to: 26)
        let nameLength = UInt64(try reader.readUInt16())
        let extraLength = UInt64(try reader.readUInt16())
        return headerOffset + UInt64(localHeaderSize) + nameLength + extraLength
    }

    // MARK: Dates

    /// MS-DOS date and time, which ZIP records in local time.
    static func dosDate(date: UInt16, time: UInt16) -> Date? {
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        guard (1...12).contains(components.month!), (1...31).contains(components.day!),
              components.hour! < 24, components.minute! < 60, components.second! < 60
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)
    }

    /// The most precise modification date in the extra fields: Info-ZIP
    /// extended timestamp (UTC seconds) or NTFS (100 ns ticks since 1601).
    static func modificationDate(extraFields: [UInt16: [UInt8]]) -> Date? {
        if let field = extraFields[ZIPExtraFieldID.extendedTimestamp] {
            var reader = BinaryReader(field)
            if let flags = try? reader.readUInt8(), flags & 1 != 0,
               let seconds = try? reader.readUInt32() {
                return Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: seconds)))
            }
        }
        if let field = extraFields[ZIPExtraFieldID.ntfs] {
            var reader = BinaryReader(field)
            _ = try? reader.readUInt32() // reserved
            while reader.remaining >= 4 {
                guard let tag = try? reader.readUInt16(), let size = try? reader.readUInt16() else { break }
                if tag == 1, size >= 8, let ticks = try? reader.readUInt64() {
                    let secondsFrom1601To1970: TimeInterval = 11_644_473_600
                    return Date(timeIntervalSince1970: TimeInterval(ticks) / 10_000_000 - secondsFrom1601To1970)
                }
                guard (try? reader.skip(Int(size))) != nil else { break }
            }
        }
        return nil
    }
}
