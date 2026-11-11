import Foundation
import XCTest
@testable import ArchiveKit

final class ArchiveExtractorTests: XCTestCase {
    func testExtractsWholeArchiveWithMetadata() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let extractor = try ArchiveExtractor(destination: destination)

        let result = try await extractor.extract(archive.entries, from: archive)
        XCTAssertEqual(result.extracted.count, 10)
        XCTAssertTrue(result.failures.isEmpty)

        let holiday = destination.appendingPathComponent("Holiday")
        XCTAssertEqual(try String(contentsOf: holiday.appendingPathComponent("notes.txt"), encoding: .utf8), "Hello, world!\n")
        XCTAssertEqual(try Data(contentsOf: holiday.appendingPathComponent("big.txt")).count, 300_000)
        XCTAssertEqual(try Data(contentsOf: holiday.appendingPathComponent("empty.txt")).count, 0)

        XCTAssertEqual(try posixPermissions(at: holiday.appendingPathComponent("run.sh")), 0o755)
        XCTAssertEqual(try posixPermissions(at: holiday.appendingPathComponent("stored.txt")), 0o600)
        XCTAssertEqual(try posixPermissions(at: holiday.appendingPathComponent("setuid")), 0o755, "setuid is stripped")
        XCTAssertEqual(try posixPermissions(at: holiday.appendingPathComponent("Photos")), 0o700)

        let expectedDate = try XCTUnwrap(try archive.entry("README").modificationDate)
        for path in ["README", "Holiday", "Holiday/notes.txt"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(path).path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, expectedDate, path)
        }
    }

    func testExtractsSingleEntryWithItsPath() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let url = try await archive.extract(try archive.entry("Holiday/Photos/beach.txt"), to: destination)
        XCTAssertEqual(url, destination.appendingPathComponent("Holiday/Photos/beach.txt"))
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(url), encoding: .utf8), String(repeating: "sand ", count: 100))
    }

    func testRemovingPrefixExtractsFolderContents() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let tree = ArchiveTree(entries: archive.entries)
        let photos = try XCTUnwrap(tree.node(atPath: "Holiday/Photos"))

        let extractor = try ArchiveExtractor(destination: destination)
        let result = try await extractor.extract(tree.entries(under: photos), from: archive, removingPrefix: "Holiday")
        XCTAssertEqual(result.extracted.map(\.path), [
            destination.appendingPathComponent("Photos").path,
            destination.appendingPathComponent("Photos/beach.txt").path,
        ])
    }

    func testReportsProgress() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let extractor = try ArchiveExtractor(destination: destination)
        var updates: [ExtractionProgress] = []
        _ = try await extractor.extract(archive.entries, from: archive) { updates.append($0) }

        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.completedEntries, 10)
        XCTAssertEqual(last.totalEntries, 10)
        XCTAssertEqual(last.completedBytes, last.totalBytes)
        XCTAssertEqual(last.fractionCompleted, 1)
        XCTAssertEqual(updates.map(\.completedBytes), updates.map(\.completedBytes).sorted())
    }

    // MARK: Conflicts

    func testConflictPolicies() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let readme = try archive.entry("README")
        let existing = destination.appendingPathComponent("README")
        try Data("existing".utf8).write(to: existing)

        await assertThrows(.destinationExists(existing.path)) {
            try await archive.extract(readme, to: destination)
        }

        let skipped = try await archive.extract(readme, to: destination, options: ExtractionOptions(conflictPolicy: .skip))
        XCTAssertNil(skipped)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")

        let kept = try await archive.extract(readme, to: destination, options: ExtractionOptions(conflictPolicy: .keepBoth))
        XCTAssertEqual(kept, destination.appendingPathComponent("README 2"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")

        let replaced = try await archive.extract(readme, to: destination, options: ExtractionOptions(conflictPolicy: .replace))
        XCTAssertEqual(replaced, existing)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "top level\n")
    }

    func testKeepBothPreservesExtension() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("basic")
        let entry = try archive.entry("Holiday/notes.txt")
        let options = ExtractionOptions(conflictPolicy: .keepBoth)
        _ = try await archive.extract(entry, to: destination, options: options)
        let second = try await archive.extract(entry, to: destination, options: options)
        XCTAssertEqual(second?.lastPathComponent, "notes 2.txt")
    }

    // MARK: Security

    func testPathTraversalIsRefused() async throws {
        let root = try makeTemporaryDirectory(self)
        let destination = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = try await openFixture("traversal")
        let extractor = try ArchiveExtractor(destination: destination)

        let result = try await extractor.extract(archive.entries, from: archive)
        XCTAssertEqual(result.extracted, [destination.appendingPathComponent("good.txt")])
        XCTAssertEqual(result.failures.map(\.entry.path), ["../../evil.txt", "/absolute.txt", "safe/../../escape.txt", "C:/windows.txt"])
        for failure in result.failures {
            XCTAssertEqual(failure.error, .unsafePath(failure.entry.path))
        }
        let written = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(written, ["a", "a/b", "a/b/c", "a/b/c/good.txt"])
    }

    func testSymlinksCannotEscapeTheDestination() async throws {
        let root = try makeTemporaryDirectory(self)
        let destination = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let archive = try await openFixture("symlinks")
        let extractor = try ArchiveExtractor(destination: destination)

        let result = try await extractor.extract(archive.entries, from: archive)
        XCTAssertEqual(result.failures.map(\.entry.path), ["escape", "absolute-link"])
        XCTAssertEqual(result.failures.first?.error, .unsafeSymlink(path: "escape", target: "../../../../tmp"))

        // "escape/pwned.txt" lands in a real folder inside the destination.
        let escape = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("escape").path)
        XCTAssertEqual(escape[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("escape/pwned.txt").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["dest"])
    }

    func testContainedSymlinkIsCreated() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("symlinks")
        let extractor = try ArchiveExtractor(destination: destination)
        _ = try await extractor.extract(archive.entries, from: archive)

        let link = destination.appendingPathComponent("dir/link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "target.txt")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "target")
    }

    func testDoesNotWriteThroughPreexistingSymlinks() async throws {
        let root = try makeTemporaryDirectory(self)
        let destination = root.appendingPathComponent("dest")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Holiday"), withDestinationURL: outside)

        let archive = try await openFixture("basic")
        await assertThrows(.unsafePath(destination.appendingPathComponent("Holiday").path)) {
            try await archive.extract(try archive.entry("Holiday/notes.txt"), to: destination)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testCorruptEntryLeavesNoPartialFile() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("bad_crc")
        let extractor = try ArchiveExtractor(destination: destination)
        let result = try await extractor.extract(archive.entries, from: archive)
        XCTAssertEqual(result.extracted, [destination.appendingPathComponent("good.txt")])
        XCTAssertEqual(result.failures.map(\.entry.path), ["bad.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("bad.txt").path))
    }

    func testLyingSizesDoNotBreakExtraction() async throws {
        let destination = try makeTemporaryDirectory(self)
        let archive = try await openFixture("lying_size")
        let extractor = try ArchiveExtractor(destination: destination)
        var last: ExtractionProgress?
        let result = try await extractor.extract(archive.entries, from: archive) { last = $0 }
        XCTAssertEqual(result.failures.map(\.entry.path), ["bomb.txt", "short.txt"])
        XCTAssertEqual(last?.completedEntries, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testDestinationMustBeAFolder() throws {
        let directory = try makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try ArchiveExtractor(destination: file))
        XCTAssertThrowsError(try ArchiveExtractor(destination: directory.appendingPathComponent("missing")))
    }
}
