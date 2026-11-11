import Foundation
import XCTest
@testable import ArchiveKit

final class CRC32Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }

    func testIncrementalMatchesOneShot() {
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var crc = CRC32()
        crc.update(data.prefix(1234))
        crc.update(data.dropFirst(1234))
        XCTAssertEqual(crc.value, CRC32.checksum(data))
    }
}

final class BinaryReaderTests: XCTestCase {
    func testLittleEndianReads() throws {
        var reader = BinaryReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        XCTAssertEqual(try reader.readUInt8(), 0x01)
        XCTAssertEqual(try reader.readUInt16(), 0x0302)
        XCTAssertEqual(try reader.readUInt32(), 0x0706_0504)
        XCTAssertEqual(try reader.readUInt64(), 0x0F0E_0D0C_0B0A_0908)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadsPastTheEndThrow() throws {
        var reader = BinaryReader([0x01, 0x02, 0x03])
        XCTAssertThrowsError(try reader.readUInt32())
        XCTAssertEqual(reader.offset, 0, "a failed read does not move the cursor")
        XCTAssertThrowsError(try reader.readBytes(4))
        XCTAssertThrowsError(try reader.readBytes(-1))
        XCTAssertThrowsError(try reader.skip(4))
        XCTAssertThrowsError(try reader.seek(to: 4))
        XCTAssertEqual(try reader.readBytes(3), [0x01, 0x02, 0x03])
    }
}

final class PathSanitizerTests: XCTestCase {
    func testSafePaths() throws {
        XCTAssertEqual(try PathSanitizer.safeComponents(of: "a/b/c.txt"), ["a", "b", "c.txt"])
        XCTAssertEqual(try PathSanitizer.safeComponents(of: "./a//b/./c"), ["a", "b", "c"])
        XCTAssertEqual(try PathSanitizer.safeComponents(of: "a\\b"), ["a", "b"])
        XCTAssertEqual(try PathSanitizer.safeComponents(of: "..foo/bar.."), ["..foo", "bar.."])
        XCTAssertEqual(try PathSanitizer.safeComponents(of: "ab:c"), ["ab:c"])
    }

    func testUnsafePaths() {
        for path in ["../x", "a/../../x", "a/..", "/etc/passwd", "\\\\server\\share", "C:/x", "c:\\x", "a:b", "", ".", "./", "a\0b"] {
            XCTAssertThrowsError(try PathSanitizer.safeComponents(of: path), path) { error in
                XCTAssertEqual(error as? ArchiveError, .unsafePath(path))
            }
        }
    }

    func testSymlinkContainment() {
        XCTAssertTrue(PathSanitizer.isSymlinkTargetContained("target.txt", linkComponents: ["dir", "link"]))
        XCTAssertTrue(PathSanitizer.isSymlinkTargetContained("../other/file", linkComponents: ["dir", "link"]))
        XCTAssertTrue(PathSanitizer.isSymlinkTargetContained("./x/../y", linkComponents: ["link"]))
        XCTAssertFalse(PathSanitizer.isSymlinkTargetContained("../..", linkComponents: ["dir", "link"]))
        XCTAssertFalse(PathSanitizer.isSymlinkTargetContained("../x", linkComponents: ["link"]))
        XCTAssertFalse(PathSanitizer.isSymlinkTargetContained("/etc", linkComponents: ["link"]))
        XCTAssertFalse(PathSanitizer.isSymlinkTargetContained("", linkComponents: ["link"]))
    }
}

final class FilenameDecoderTests: XCTestCase {
    func testCP437() {
        XCTAssertEqual(ZIPFilenameDecoder.decodeCP437([0x63, 0x61, 0x66, 0x82]), "café")
        XCTAssertEqual(ZIPFilenameDecoder.decodeCP437([0x80, 0x9E, 0xE1, 0xFF]), "Ç₧ß\u{A0}")
    }

    func testAutomaticPrefersValidUTF8() {
        let utf8 = Array("日本".utf8)
        XCTAssertEqual(ZIPFilenameDecoder.decode(raw: utf8, isUTF8Flagged: false, unicodePathExtra: nil, fallback: .automatic), "日本")
        XCTAssertEqual(ZIPFilenameDecoder.decode(raw: utf8, isUTF8Flagged: false, unicodePathExtra: nil, fallback: .cp437), "µùÑµ£¼")
    }

    func testStaleUnicodePathFieldIsIgnored() {
        var extra: [UInt8] = [1, 0, 0, 0, 0] // CRC of zero does not match "a.txt"
        extra += Array("b.txt".utf8)
        XCTAssertEqual(ZIPFilenameDecoder.decode(raw: Array("a.txt".utf8), isUTF8Flagged: false, unicodePathExtra: extra, fallback: .automatic), "a.txt")
    }
}

final class ArchiveTreeTests: XCTestCase {
    func testSynthesisesImplicitFolders() async throws {
        let archive = try await openFixture("implicit_dirs")
        let tree = ArchiveTree(entries: archive.entries, archiveName: "implicit_dirs.zip")
        XCTAssertEqual(tree.root.name, "implicit_dirs.zip")
        XCTAssertEqual(tree.root.children.map(\.name), ["a", "e.txt"])

        let a = try XCTUnwrap(tree.node(atPath: "a"))
        XCTAssertTrue(a.isDirectory)
        XCTAssertNil(a.entry)
        XCTAssertLessThan(a.id, 0)
        XCTAssertEqual(a.children.map(\.name), ["b", "d.txt"])
        XCTAssertEqual(a.directoryChildren.map(\.name), ["b"])
        XCTAssertEqual(tree.node(atPath: "a/b/c.txt")?.entry?.path, "a/b/c.txt")
        XCTAssertNil(tree.node(atPath: "a/missing"))

        XCTAssertEqual(tree.root.totalUncompressedSize, 3)
        XCTAssertEqual(tree.root.descendantFileCount, 3)
        XCTAssertEqual(tree.entries(under: a).map(\.path), ["a/b/c.txt", "a/d.txt"])
    }

    func testExplicitFoldersKeepTheirEntries() async throws {
        let archive = try await openFixture("basic")
        let tree = ArchiveTree(entries: archive.entries)
        let holiday = try XCTUnwrap(tree.node(atPath: "Holiday"))
        XCTAssertEqual(holiday.entry?.path, "Holiday")
        XCTAssertEqual(holiday.children.map(\.name), ["big.txt", "empty.txt", "notes.txt", "Photos", "run.sh", "setuid", "stored.txt"])
        XCTAssertEqual(tree.entries(under: tree.root).count, archive.entries.count)
    }

    func testHidesMacOSMetadataByDefault() {
        let entries = [
            ArchiveEntry(id: 0, path: "file.txt", type: .file, compressedSize: 1, uncompressedSize: 1, modificationDate: nil, compressionMethod: .stored, crc32: nil),
            ArchiveEntry(id: 1, path: "__MACOSX/._file.txt", type: .file, compressedSize: 1, uncompressedSize: 1, modificationDate: nil, compressionMethod: .stored, crc32: nil),
        ]
        XCTAssertEqual(ArchiveTree(entries: entries).root.children.map(\.name), ["file.txt"])
        XCTAssertEqual(ArchiveTree(entries: entries, includeMacOSMetadata: true).root.children.map(\.name), ["__MACOSX", "file.txt"])
    }

    func testNumericOrdering() {
        let entries = ["file10", "file2", "File1"].enumerated().map {
            ArchiveEntry(id: $0.offset, path: $0.element, type: .file, compressedSize: 0, uncompressedSize: 0, modificationDate: nil, compressionMethod: .stored, crc32: nil)
        }
        XCTAssertEqual(ArchiveTree(entries: entries).root.children.map(\.name), ["File1", "file2", "file10"])
    }
}
