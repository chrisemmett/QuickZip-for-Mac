import Foundation
import XCTest
@testable import ArchiveKit

/// Filename, path and extension search (HLD §12).
final class ArchiveSearchIndexTests: XCTestCase {
    private func makeIndex() -> (ArchiveTree, ArchiveSearchIndex) {
        let paths = [
            "Holiday/Photos/Beach.JPG", "Holiday/Photos/hotel.jpg", "Holiday/notes.txt",
            "Work/Report Final.pdf", "Work/Résumé.pdf", "Work/archive.tar.gz", "readme",
        ]
        let entries = paths.enumerated().map { index, path in
            ArchiveEntry(id: index, path: path, type: .file, compressedSize: 1, uncompressedSize: 1,
                         modificationDate: nil, compressionMethod: .stored, crc32: nil)
        }
        let tree = ArchiveTree(entries: entries)
        return (tree, ArchiveSearchIndex(tree: tree))
    }

    private func names(_ nodes: [ArchiveNode]) -> [String] {
        nodes.map(\.name).sorted()
    }

    func testNameSearchIgnoresCaseAndDiacritics() {
        let (_, index) = makeIndex()
        XCTAssertEqual(names(index.search("beach")), ["Beach.JPG"])
        XCTAssertEqual(names(index.search("resume")), ["Résumé.pdf"])
        XCTAssertEqual(names(index.search("PHOTOS")), ["Photos"])
        XCTAssertEqual(names(index.search("o")), ["Holiday", "Photos", "Report Final.pdf", "Work", "hotel.jpg", "notes.txt"])
    }

    func testEveryTermMustMatch() {
        let (_, index) = makeIndex()
        XCTAssertEqual(names(index.search("report pdf")), ["Report Final.pdf"])
        XCTAssertEqual(names(index.search("report jpg")), [])
    }

    func testExtensionSearch() {
        let (_, index) = makeIndex()
        XCTAssertEqual(names(index.search("*.jpg")), ["Beach.JPG", "hotel.jpg"])
        XCTAssertEqual(names(index.search("ext:PDF")), ["Report Final.pdf", "Résumé.pdf"])
        XCTAssertEqual(names(index.search("*.gz")), ["archive.tar.gz"])
        // Folders have no extension.
        XCTAssertEqual(names(index.search("ext:")), [])
    }

    func testPathSearch() {
        let (_, index) = makeIndex()
        XCTAssertEqual(names(index.search("photos/")), ["Beach.JPG", "hotel.jpg"])
        XCTAssertEqual(names(index.search("work/r")), ["Report Final.pdf", "Résumé.pdf"])
    }

    func testSearchWithinFolder() throws {
        let (tree, index) = makeIndex()
        let holiday = try XCTUnwrap(tree.node(atPath: "Holiday"))
        XCTAssertEqual(names(index.search("o", in: holiday)), ["Photos", "hotel.jpg", "notes.txt"])
        let photos = try XCTUnwrap(tree.node(atPath: "Holiday/Photos"))
        XCTAssertEqual(names(index.search("e", in: photos)), ["Beach.JPG", "hotel.jpg"])
        XCTAssertEqual(names(index.search("o", in: tree.root)).count, 6)
    }

    func testEmptyQueryMatchesNothing() {
        let (_, index) = makeIndex()
        XCTAssertTrue(index.search("").isEmpty)
        XCTAssertTrue(index.search("   ").isEmpty)
        XCTAssertEqual(index.count, 10)
    }

    func testSearchOver100000EntriesIsFast() {
        let entries = (0..<100_000).map { index in
            ArchiveEntry(id: index, path: "Folder \(index % 100)/file \(index).txt", type: .file, compressedSize: 1,
                         uncompressedSize: 1, modificationDate: nil, compressionMethod: .stored, crc32: nil)
        }
        let index = ArchiveSearchIndex(tree: ArchiveTree(entries: entries))
        XCTAssertEqual(index.search("file 99999").count, 1)
        let start = Date()
        for query in ["f", "fi", "fil", "file", "file 1", "file 12", "*.txt", "older 5/"] {
            _ = index.search(query)
        }
        let perQuery = Date().timeIntervalSince(start) / 8
        // Generous, for debug builds and shared CI machines; the target is
        // 16 ms in release builds.
        XCTAssertLessThan(perQuery, 0.25)
    }
}
