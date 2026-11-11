import XCTest
@testable import ArchiveKit

/// Inputs that used to trap (an uncaught runtime error) rather than throw.
/// Each archive is built in memory, so the exact bytes are visible here.
final class CrashRegressionTests: XCTestCase {
    // MARK: ZIP

    /// A ZIP64 compressed size of UInt64.max overflowed when the overlap
    /// check added the local header length to it.
    func testZIP64SizeNearMaximumIsReportedAsOverlapping() async throws {
        var directory: [UInt8] = []
        directory += centralRecord(name: "huge", offset: 0, compressed32: 0xFFFF_FFFF,
                                   extra: le16(0x0001) + le16(8) + le64(.max))
        directory += centralRecord(name: "next", offset: 100, compressed32: 0, extra: [])
        let bytes = directory + endOfCentralDirectory(count: 2, size: directory.count, offset: 0)

        let archive = try await ZIPArchive.open(try write(bytes, as: "zip"))
        XCTAssertEqual(archive.entries.map(\.path), ["huge", "next"])
        XCTAssertEqual(archive.overlappingEntryIDs, [0, 1])
    }

    // MARK: tar

    /// A pax record whose length is Int.max overflowed when added to the
    /// position of the record.
    func testPaxRecordLengthNearIntMaxStopsParsing() {
        let records = TarIndexer.paxRecords(Array("11 a=bcdef\n9223372036854775807 x=y\n".utf8))
        XCTAssertEqual(records, ["a": "bcdef"])
    }

    /// A pax `size` of UInt64.max overflowed `position + size`.
    func testPlainTarWithHugePaxSizeIsCutShort() async throws {
        let bytes = paxHeader(["size": "18446744073709551615"]) + tarHeader(name: "big.bin", size: 0) + endOfTar
        let archive = try await TarArchive.open(try write(bytes, as: "tar"), compression: .none)
        XCTAssertEqual(archive.entries.map(\.path), ["big.bin"])
        XCTAssertFalse(archive.warnings.isEmpty)
    }

    /// A device whose base-256 size field holds UInt64.max overflowed
    /// rounding the size up to whole blocks.
    func testPlainTarWithHugeSpecialFileSizeStops() async throws {
        var device = tarHeader(name: "dev", size: 0, type: UInt8(ascii: "3"))
        device.replaceSubrange(124..<136, with: [0x80, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 8))
        resum(&device)
        let archive = try await TarArchive.open(try write(device + endOfTar, as: "tar"), compression: .none)
        XCTAssertTrue(archive.entries.isEmpty)
    }

    /// In a compressed tar, the same size overflowed `Int.max + padding`
    /// when the oversized entry's data was skipped.
    func testGzipTarWithHugePaxSizeIsListedButRefused() async throws {
        let tar = paxHeader(["size": "18446744073709551615"]) + tarHeader(name: "big.bin", size: 0) + endOfTar
        let archive = try await TarArchive.open(try write(gzipStored(tar), as: "tar.gz"), compression: .gzip)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.path, "big.bin")
        do {
            try await archive.read(entry) { _ in }
            XCTFail("an entry declaring UInt64.max bytes was read")
        } catch ArchiveError.exceedsLimits {
        }
    }

    /// pax accepts `mtime=inf`; such a date later reached `time_t(Double)`.
    func testInfiniteAndAbsurdModificationTimesAreDropped() async throws {
        for mtime in ["inf", "nan", "1e300"] {
            let bytes = paxHeader(["mtime": mtime]) + tarHeader(name: "file", size: 0) + endOfTar
            let archive = try await TarArchive.open(try write(bytes, as: "tar"), compression: .none)
            XCTAssertEqual(archive.entries.map(\.path), ["file"], mtime)
            XCTAssertNil(archive.entries.first?.modificationDate, mtime)
        }
        XCTAssertNotNil(plausibleDate(secondsSince1970: 1_700_000_000))
    }

    // MARK: Trees and comparisons

    /// A path 100,000 folders deep overflowed the stack while the tree was
    /// built, walked and freed, all of which recurse once per level.
    func testVeryDeepPathIsCappedInTheTree() async throws {
        let path = Array(repeating: "a", count: 100_000).joined(separator: "/")
        let entry = ArchiveEntry(id: 0, path: path, type: .file, compressedSize: 1, uncompressedSize: 1,
                                 modificationDate: nil, compressionMethod: .stored, crc32: nil)
        let depth = await Task.detached { () -> Int in
            let tree = ArchiveTree(entries: [entry])
            XCTAssertEqual(tree.entries(under: tree.root), [entry])
            XCTAssertFalse(ArchiveListing.html(archiveName: "deep.zip", entries: [entry]).isEmpty)
            var depth = 0
            var node = tree.root
            while let child = node.children.first {
                depth += 1
                node = child
            }
            XCTAssertEqual(node.entry, entry)
            return depth
        }.value
        XCTAssertEqual(depth, ArchiveTree.maximumDepth)
    }

    /// Two items with the same path had the same id, which SwiftUI lists
    /// cannot handle.
    func testComparisonItemsHaveUniqueIDsForDuplicatePaths() async throws {
        let duplicates = (0..<2).map {
            ArchiveEntry(id: $0, path: "same.txt", type: .file, compressedSize: UInt64($0), uncompressedSize: UInt64($0),
                         modificationDate: nil, compressionMethod: .stored, crc32: 0)
        }
        let result = try await ArchiveComparison.compare(archive: [], with: .archive(duplicates))
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(Set(result.items.map(\.id)).count, 2)
    }

    // MARK: Builders

    private func write(_ bytes: [UInt8], as ext: String) throws -> URL {
        let url = try makeTemporaryDirectory(self).appendingPathComponent("archive.\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    private func le16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private func le64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

    private func centralRecord(name: String, offset: UInt32, compressed32: UInt32, extra: [UInt8]) -> [UInt8] {
        let name = Array(name.utf8)
        var record = le32(ZIPSignature.centralDirectoryHeader)
        record += le16(20) + le16(20) + le16(0) + le16(0) // made by, needed, flags, method
        record += le16(0) + le16(0x21) + le32(0)          // time, date, CRC
        record += le32(compressed32) + le32(10)           // compressed, uncompressed
        record += le16(UInt16(name.count)) + le16(UInt16(extra.count)) + le16(0)
        record += le16(0) + le16(0) + le32(0) + le32(offset)
        return record + name + extra
    }

    private func endOfCentralDirectory(count: UInt16, size: Int, offset: UInt32) -> [UInt8] {
        le32(ZIPSignature.endOfCentralDirectory) + le16(0) + le16(0) + le16(count) + le16(count)
            + le32(UInt32(size)) + le32(offset) + le16(0)
    }

    private let endOfTar = [UInt8](repeating: 0, count: 1024)

    private func tarHeader(name: String, size: Int, type: UInt8 = UInt8(ascii: "0")) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() { block[offset + index] = byte }
        }
        put(name, at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        put(String(size, radix: 8).leftPadded(to: 11), at: 124)
        put("00000000000", at: 136)
        block[156] = type
        put("ustar\0", at: 257)
        put("00", at: 263)
        resum(&block)
        return block
    }

    /// Recomputes a header's checksum after it has been changed.
    private func resum(_ block: inout [UInt8]) {
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let field = Array((String(sum, radix: 8).leftPadded(to: 6) + "\0 ").utf8)
        block.replaceSubrange(148..<156, with: field)
    }

    private func paxHeader(_ values: [String: String]) -> [UInt8] {
        var data: [UInt8] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let body = " \(key)=\(value)\n"
            var length = body.utf8.count
            while length != body.utf8.count + String(length).count { length = body.utf8.count + String(length).count }
            data += Array("\(length)\(body)".utf8)
        }
        let padding = (512 - data.count % 512) % 512
        return tarHeader(name: "PaxHeader", size: data.count, type: UInt8(ascii: "x")) + data + [UInt8](repeating: 0, count: padding)
    }

    /// gzip holding `bytes` in one stored (uncompressed) DEFLATE block.
    private func gzipStored(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= 0xFFFF)
        let length = UInt16(bytes.count)
        return [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3]
            + [0x01] + le16(length) + le16(~length)
            + bytes
            + le32(CRC32.checksum(bytes)) + le32(UInt32(bytes.count))
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
