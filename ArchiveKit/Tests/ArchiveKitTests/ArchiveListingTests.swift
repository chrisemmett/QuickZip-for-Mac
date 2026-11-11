import XCTest
@testable import ArchiveKit

final class ArchiveListingTests: XCTestCase {
    private func file(_ path: String, id: Int, size: UInt64 = 100) -> ArchiveEntry {
        ArchiveEntry(id: id, path: path, type: .file, compressedSize: size / 2, uncompressedSize: size,
                     modificationDate: nil, compressionMethod: .deflate, crc32: nil)
    }

    func testNamesAreEscaped() {
        let html = ArchiveListing.html(
            archiveName: "<b>x</b>.zip",
            entries: [file("a/<script>alert(1)</script>\".txt", id: 0), file("it's & that.txt", id: 1)],
            locale: Locale(identifier: "en_US")
        )
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<b>x"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("it&#39;s &amp; that.txt"))
    }

    func testHasNoScriptOrExternalReferences() {
        let html = ArchiveListing.html(archiveName: "a.zip", entries: [file("x.txt", id: 0)])
        XCTAssertTrue(html.contains("default-src 'none'"))
        for forbidden in ["<script", "http://", "https://", "src=", "<link"] {
            XCTAssertFalse(html.contains(forbidden), forbidden)
        }
    }

    func testRowsAreCapped() {
        let entries = (0..<(ArchiveListing.rowLimit + 25)).map { file("f\($0).txt", id: $0) }
        let html = ArchiveListing.html(archiveName: "big.zip", entries: entries)
        XCTAssertEqual(html.components(separatedBy: "<tr class=\"file\"").count - 1, ArchiveListing.rowLimit)
        XCTAssertTrue(html.contains("…and 25 more items"))
    }

    func testSummaryAndFoldersAndFlags() {
        let html = ArchiveListing.html(
            archiveName: "p.zip",
            entries: [file("dir/a.txt", id: 0, size: 1_000_000), file("dir/b.sh", id: 1)],
            flaggedEntryIDs: [1],
            locale: Locale(identifier: "en_US")
        )
        XCTAssertTrue(html.contains("2 items"))
        XCTAssertTrue(html.contains("class=\"dir\""))
        XCTAssertTrue(html.contains("1 item to be careful with"))
        XCTAssertTrue(html.contains("⚠︎ <bdi>b.sh"))
    }

    func testEmptyArchive() {
        XCTAssertTrue(ArchiveListing.html(archiveName: "e.zip", entries: []).contains("This archive is empty."))
    }

    func testRealArchive() async throws {
        let archive = try await openFixture("mixed")
        let html = ArchiveListing.html(archiveName: "mixed.zip", entries: archive.entries)
        XCTAssertTrue(html.contains("<table>"))
    }
}
