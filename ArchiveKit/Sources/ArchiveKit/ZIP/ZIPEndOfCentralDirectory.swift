import Foundation

/// The location of the central directory, taken from the End of Central
/// Directory record and, when present, its ZIP64 counterpart (APPNOTE 4.3.14–16).
struct ZIPEndOfCentralDirectory {
    /// Offset of the EOCD record within the file.
    var recordOffset: UInt64
    var entryCount: UInt64
    var centralDirectorySize: UInt64
    /// Offset of the central directory as written in the archive. Self-
    /// extracting archives prepend data without adjusting this; see
    /// `ZIPArchive` for how the difference is corrected.
    var centralDirectoryOffset: UInt64
    /// Where the directory structures start: the ZIP64 record if present,
    /// otherwise the EOCD record. The central directory must end here.
    var directoryEnd: UInt64
    var isZIP64: Bool
    /// The archive comment, kept so that a rewrite preserves it.
    var comment: Data = Data()

    static let recordSize = 22
    private static let maxCommentLength = 0xFFFF
    private static let zip64LocatorSize = 20
    private static let zip64RecordMinimumSize = 56

    /// Finds and parses the EOCD by scanning backwards from the end of the
    /// file, then follows the ZIP64 locator if the record calls for it.
    static func locate(in file: RandomAccessFile) throws -> ZIPEndOfCentralDirectory {
        let fileSize = file.size
        guard fileSize >= UInt64(recordSize) else { throw ArchiveError.notAnArchive }

        let searchLength = min(fileSize, UInt64(recordSize + maxCommentLength))
        let searchStart = fileSize - searchLength
        let tail = [UInt8](try file.read(at: searchStart, count: Int(searchLength)))

        var candidate = tail.count - recordSize
        while candidate >= 0 {
            if tail[candidate] == 0x50, tail[candidate + 1] == 0x4B,
               tail[candidate + 2] == 0x05, tail[candidate + 3] == 0x06 {
                var reader = BinaryReader(Array(tail[candidate...]))
                if let record = try? parseRecord(&reader, offset: searchStart + UInt64(candidate)) {
                    return try resolveZIP64(record, in: file)
                }
            }
            candidate -= 1
        }
        throw ArchiveError.notAnArchive
    }

    private static func parseRecord(_ reader: inout BinaryReader, offset: UInt64) throws -> ZIPEndOfCentralDirectory {
        _ = try reader.readUInt32() // signature
        let diskNumber = try reader.readUInt16()
        let directoryDisk = try reader.readUInt16()
        let entriesOnDisk = try reader.readUInt16()
        let totalEntries = try reader.readUInt16()
        let size = try reader.readUInt32()
        let directoryOffset = try reader.readUInt32()
        let commentLength = try reader.readUInt16()
        // A comment longer than the remaining bytes means this is a false
        // match inside other data (for example an earlier comment).
        guard Int(commentLength) <= reader.remaining else {
            throw ArchiveError.malformed("end of central directory comment overruns the file")
        }
        let comment = Data(try reader.readBytes(Int(commentLength)))
        let isZIP64 = totalEntries == 0xFFFF || entriesOnDisk == 0xFFFF
            || size == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
            || diskNumber == 0xFFFF || directoryDisk == 0xFFFF
        if !isZIP64, diskNumber != 0 || directoryDisk != 0 || entriesOnDisk != totalEntries {
            throw ArchiveError.malformed("multi-volume archives are not supported")
        }
        return ZIPEndOfCentralDirectory(
            recordOffset: offset,
            entryCount: UInt64(totalEntries),
            centralDirectorySize: UInt64(size),
            centralDirectoryOffset: UInt64(directoryOffset),
            directoryEnd: offset,
            isZIP64: isZIP64,
            comment: comment
        )
    }

    private static func resolveZIP64(_ record: ZIPEndOfCentralDirectory, in file: RandomAccessFile) throws -> ZIPEndOfCentralDirectory {
        guard record.recordOffset >= UInt64(zip64LocatorSize) else {
            if record.isZIP64 { throw ArchiveError.malformed("the ZIP64 locator is missing") }
            return record
        }
        let locatorOffset = record.recordOffset - UInt64(zip64LocatorSize)
        var locator = BinaryReader(try file.read(at: locatorOffset, count: zip64LocatorSize))
        guard try locator.readUInt32() == ZIPSignature.zip64EndOfCentralDirectoryLocator else {
            if record.isZIP64 { throw ArchiveError.malformed("the ZIP64 locator is missing") }
            return record
        }
        _ = try locator.readUInt32() // disk with the ZIP64 record
        var zip64Offset = try locator.readUInt64()
        _ = try locator.readUInt32() // total disks

        // Self-extracting archives shift everything; if the record is not at
        // the stated offset, assume it immediately precedes the locator.
        if zip64Offset > locatorOffset || (try? file.read(at: zip64Offset, count: 4)).map({ [UInt8]($0) }) != [0x50, 0x4B, 0x06, 0x06] {
            guard locatorOffset >= UInt64(zip64RecordMinimumSize) else {
                throw ArchiveError.malformed("the ZIP64 end of central directory record is missing")
            }
            zip64Offset = locatorOffset - UInt64(zip64RecordMinimumSize)
        }

        var reader = BinaryReader(try file.read(at: zip64Offset, count: zip64RecordMinimumSize))
        guard try reader.readUInt32() == ZIPSignature.zip64EndOfCentralDirectory else {
            throw ArchiveError.malformed("the ZIP64 end of central directory record is missing")
        }
        _ = try reader.readUInt64() // size of remaining record
        _ = try reader.readUInt16() // version made by
        _ = try reader.readUInt16() // version needed
        let diskNumber = try reader.readUInt32()
        let directoryDisk = try reader.readUInt32()
        let entriesOnDisk = try reader.readUInt64()
        let totalEntries = try reader.readUInt64()
        let size = try reader.readUInt64()
        let directoryOffset = try reader.readUInt64()
        guard diskNumber == 0, directoryDisk == 0, entriesOnDisk == totalEntries else {
            throw ArchiveError.malformed("multi-volume archives are not supported")
        }
        return ZIPEndOfCentralDirectory(
            recordOffset: record.recordOffset,
            entryCount: totalEntries,
            centralDirectorySize: size,
            centralDirectoryOffset: directoryOffset,
            directoryEnd: zip64Offset,
            isZIP64: true,
            comment: record.comment
        )
    }
}
