import XCTest
@testable import ArchiveKit

final class ComparisonTests: XCTestCase {
    private func entry(_ path: String, _ contents: String, id: Int = 0, crc: Bool = true) -> ArchiveEntry {
        let data = Data(contents.utf8)
        return ArchiveEntry(id: id, path: path, type: .file, compressedSize: UInt64(data.count), uncompressedSize: UInt64(data.count),
                            modificationDate: nil, compressionMethod: .stored, crc32: crc ? CRC32.checksum(data) : nil)
    }

    func testAddedRemovedChangedAndUnchanged() async throws {
        let mine = [entry("a.txt", "same"), entry("b.txt", "old text"), entry("gone.txt", "x"), entry("same-size.txt", "aaaa")]
        let other = [entry("a.txt", "same"), entry("b.txt", "new text!"), entry("new.txt", "y"), entry("same-size.txt", "bbbb")]
        let result = try await ArchiveComparison.compare(archive: mine, with: .archive(other))
        XCTAssertEqual(result.items.map { "\($0.change.rawValue) \($0.path)" },
                       ["changed b.txt", "removed gone.txt", "added new.txt", "changed same-size.txt"])
        XCTAssertEqual(result.unchangedCount, 1)
        XCTAssertEqual(result.count(.changed), 2)
        XCTAssertFalse(result.isIdentical)
    }

    func testIdenticalArchives() async throws {
        let archive = try await openFixture("basic")
        let result = try await ArchiveComparison.compare(archive: archive.entries, with: .archive(archive.entries))
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(result.unchangedCount, archive.entries.filter { $0.type != .directory }.count)
    }

    func testMissingChecksumsAreUnverifiedNotUnchanged() async throws {
        let result = try await ArchiveComparison.compare(
            archive: [entry("a.txt", "same", crc: false)], with: .archive([entry("a.txt", "same")])
        )
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(result.unchangedCount, 0)
        XCTAssertEqual(result.unverifiedCount, 1)
    }

    func testFolderLinesUpWithAnArchiveOfIt() async throws {
        let folder = try makeTemporaryDirectory(self).appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("int main;".utf8).write(to: folder.appendingPathComponent("src/main.c"))
        try Data("edited".utf8).write(to: folder.appendingPathComponent("README"))
        try Data("extra".utf8).write(to: folder.appendingPathComponent("extra.txt"))
        try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("README"))

        // The archive holds "Project/…", the folder is "Project" itself.
        let archive = [entry("Project/src/main.c", "int main;"), entry("Project/README", "original"), entry("Project/old.txt", "o")]
        let result = try await ArchiveComparison.compare(archive: archive, with: .folder(folder))
        XCTAssertEqual(result.archivePrefix, "Project")
        XCTAssertNil(result.otherPrefix)
        XCTAssertEqual(result.items.map { "\($0.change.rawValue) \($0.path)" }, ["added extra.txt", "removed old.txt", "changed README"].sorted {
            $0.dropFirst($0.firstIndex(of: " ")!.utf16Offset(in: $0) + 1).localizedStandardCompare($1.dropFirst($1.firstIndex(of: " ")!.utf16Offset(in: $1) + 1)) == .orderedAscending
        })
        XCTAssertEqual(result.unchangedCount, 1)
        XCTAssertEqual(result.skippedLinkCount, 1)
    }

    func testFolderFilesAreOnlyReadWhenSizesMatch() async throws {
        // A big file of another size is never read: its mismatch is settled by size.
        let folder = try makeTemporaryDirectory(self)
        try Data(count: 3_000_000).write(to: folder.appendingPathComponent("big.bin"))
        let result = try await ArchiveComparison.compare(archive: [entry("big.bin", "small")], with: .folder(folder))
        XCTAssertEqual(result.items.map(\.change), [.changed])
    }

    func testNormalisationDoesNotCreateDifferences() async throws {
        let nfd = "cafe\u{301}.txt", nfc = "caf\u{e9}.txt"
        let result = try await ArchiveComparison.compare(archive: [entry(nfd, "x")], with: .archive([entry(nfc, "x")]))
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(result.unchangedCount, 1)
    }

    func testMacOSMetadataIsIgnored() async throws {
        let result = try await ArchiveComparison.compare(
            archive: [entry("a.txt", "x"), entry("__MACOSX/._a.txt", "meta")], with: .archive([entry("a.txt", "x")])
        )
        XCTAssertTrue(result.isIdentical)
    }
}
