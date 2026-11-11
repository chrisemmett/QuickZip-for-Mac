import Foundation
import XCTest
@testable import ArchiveKit

final class ZIPRewriterTests: XCTestCase {
    /// Fixtures a rewrite must reproduce exactly, between them covering
    /// ZIP64, data descriptors, encryption, unsupported methods, prefixed
    /// (self-extracting) archives, legacy name encodings and links.
    static let rewritableFixtures = [
        "basic", "data_descriptor", "empty", "encrypted", "implicit_dirs", "infozip",
        "mixed", "names", "prefixed", "python_zipfile", "symlinks", "traversal",
        "unsupported_methods", "zeros", "zip64", "lzma", "aes256", "zipcrypto",
    ]

    func testRewritingWithoutChangesPreservesEveryEntry() async throws {
        let directory = try makeTemporaryDirectory(self)
        for name in Self.rewritableFixtures {
            let original = try await openFixture(name)
            XCTAssertNil(original.rewriteBlocker, name)
            let copyURL = directory.appendingPathComponent("\(name).zip")
            try await original.rewrite(to: copyURL, removing: [], adding: [])
            let copy = try await ZIPArchive.open(copyURL)

            XCTAssertEqual(copy.warnings, [], name)
            XCTAssertEqual(copy.entries.count, original.entries.count, name)
            for (before, after) in zip(original.entries, copy.entries) {
                XCTAssertEqual(after.path, before.path, name)
                XCTAssertEqual(after.type, before.type, name)
                XCTAssertEqual(after.crc32, before.crc32, name)
                XCTAssertEqual(after.compressedSize, before.compressedSize, name)
                XCTAssertEqual(after.uncompressedSize, before.uncompressedSize, name)
                XCTAssertEqual(after.compressionMethod, before.compressionMethod, name)
                XCTAssertEqual(after.isEncrypted, before.isEncrypted, name)
                XCTAssertEqual(after.posixPermissions, before.posixPermissions, name)
                XCTAssertEqual(after.modificationDate, before.modificationDate, name)
                if before.isReadable && !before.needsPassword && before.type != .directory {
                    // Some fixtures hold deliberately invalid data: the copy
                    // must fail in the same way.
                    let expected = try? await original.contents(of: before)
                    let actual = try? await copy.contents(of: after)
                    XCTAssertEqual(actual, expected, "\(name): \(before.path)")
                }
            }
            try assertValidForOtherTools(copyURL, likeOriginal: fixtureURL(name))
        }
    }

    func testDamagedArchivesCannotBeRewritten() async throws {
        for name in ["damaged_directory", "truncated", "overlapping"] {
            let archive = try await openFixture(name)
            XCTAssertNotNil(archive.rewriteBlocker, name)
            let destination = try makeTemporaryDirectory(self).appendingPathComponent("out.zip")
            do {
                try await archive.rewrite(to: destination, removing: [], adding: [])
                XCTFail("\(name) was rewritten")
            } catch {}
        }
    }

    func testRemovingEntries() async throws {
        let original = try await openFixture("basic")
        let removed = try original.entry("Holiday/notes.txt")
        let destination = try makeTemporaryDirectory(self).appendingPathComponent("out.zip")
        try await original.rewrite(to: destination, removing: [removed.id], adding: [])

        let copy = try await ZIPArchive.open(destination)
        XCTAssertEqual(copy.entries.map(\.path), original.entries.map(\.path).filter { $0 != removed.path })
        let beach = try await copy.string("Holiday/Photos/beach.txt")
        let expectedBeach = try await original.string("Holiday/Photos/beach.txt")
        XCTAssertEqual(beach, expectedBeach)
        try assertValidForOtherTools(destination)
    }

    func testAddingFilesFoldersAndLinks() async throws {
        let directory = try makeTemporaryDirectory(self)
        let text = directory.appendingPathComponent("added.txt")
        let repetitive = String(repeating: "compressible ", count: 10_000)
        try repetitive.write(to: text, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o640], ofItemAtPath: text.path)

        // Random bytes don't compress, so they must be stored.
        let random = directory.appendingPathComponent("random.bin")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<50_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).write(to: random)

        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: folder.appendingPathComponent("Inner/file.txt"))
        try Data().write(to: folder.appendingPathComponent("empty.txt"))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "Inner/file.txt")

        let original = try await openFixture("basic")
        let destination = directory.appendingPathComponent("out.zip")
        try await original.rewrite(to: destination, removing: [], adding: [
            ArchiveAddition(source: text, path: "Holiday/added.txt"),
            ArchiveAddition(source: random, path: "random.bin"),
            ArchiveAddition(source: folder, path: "Holiday/Café Folder"),
        ])

        let copy = try await ZIPArchive.open(destination)
        XCTAssertEqual(copy.warnings, [])
        let paths = copy.entries.map(\.path)
        XCTAssertEqual(Array(paths.prefix(original.entries.count)), original.entries.map(\.path))
        XCTAssertEqual(Set(paths.dropFirst(original.entries.count)), [
            "Holiday/added.txt",
            "random.bin",
            "Holiday/Café Folder",
            "Holiday/Café Folder/Inner",
            "Holiday/Café Folder/Inner/file.txt",
            "Holiday/Café Folder/empty.txt",
            "Holiday/Café Folder/link",
        ])

        let added = try copy.entry("Holiday/added.txt")
        #if canImport(Compression)
        XCTAssertEqual(added.compressionMethod, .deflate)
        XCTAssertLessThan(added.compressedSize, added.uncompressedSize / 10)
        #else
        XCTAssertEqual(added.compressionMethod, .stored) // no encoder on Linux
        #endif
        XCTAssertEqual(added.posixPermissions, 0o640)
        XCTAssertEqual(added.modificationDate, date)
        let addedText = try await copy.string("Holiday/added.txt")
        XCTAssertEqual(addedText, repetitive)

        let stored = try copy.entry("random.bin")
        XCTAssertEqual(stored.compressionMethod, .stored)
        let storedData = try await copy.contents(of: stored)
        XCTAssertEqual(storedData, try Data(contentsOf: random))

        XCTAssertEqual(try copy.entry("Holiday/Café Folder/Inner").type, .directory)
        let inner = try await copy.string("Holiday/Café Folder/Inner/file.txt")
        XCTAssertEqual(inner, "inner")
        XCTAssertEqual(try copy.entry("Holiday/Café Folder/empty.txt").uncompressedSize, 0)
        let link = try copy.entry("Holiday/Café Folder/link")
        XCTAssertEqual(link.type, .symlink)
        let linkTarget = try await copy.string("Holiday/Café Folder/link")
        XCTAssertEqual(linkTarget, "Inner/file.txt")

        try assertValidForOtherTools(destination)
    }

    func testRewrittenArchiveCanBeRewrittenAgain() async throws {
        let directory = try makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("new.txt")
        try Data("new".utf8).write(to: file)

        let first = directory.appendingPathComponent("first.zip")
        let original = try await openFixture("zip64")
        try await original.rewrite(to: first, removing: [], adding: [ArchiveAddition(source: file, path: "new.txt")])
        let firstArchive = try await ZIPArchive.open(first)
        let second = directory.appendingPathComponent("second.zip")
        try await firstArchive.rewrite(to: second, removing: [try firstArchive.entry("one.txt").id], adding: [])

        let result = try await ZIPArchive.open(second)
        XCTAssertEqual(result.entries.map(\.path), ["dir/two.txt", "new.txt"])
        let text = try await result.string("new.txt")
        XCTAssertEqual(text, "new")
        try assertValidForOtherTools(second)
    }

    func testAddingAnExistingPathIsRefused() async throws {
        let directory = try makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let original = try await openFixture("basic")

        await assertThrows(.destinationExists("Holiday/notes.txt")) {
            try await original.rewrite(
                to: directory.appendingPathComponent("a.zip"),
                removing: [],
                adding: [ArchiveAddition(source: file, path: "Holiday/notes.txt")]
            )
        }
        // Replacing: remove the old entry in the same rewrite.
        let destination = directory.appendingPathComponent("b.zip")
        try await original.rewrite(
            to: destination,
            removing: [try original.entry("Holiday/notes.txt").id],
            adding: [ArchiveAddition(source: file, path: "Holiday/notes.txt")]
        )
        let replaced = try await ZIPArchive.open(destination).string("Holiday/notes.txt")
        XCTAssertEqual(replaced, "x")
    }

    func testUnsafeAdditionPathsAreRefused() async throws {
        let directory = try makeTemporaryDirectory(self)
        let file = directory.appendingPathComponent("f.txt")
        try Data().write(to: file)
        let original = try await openFixture("basic")
        for path in ["", "/abs.txt", "../up.txt", "a/../b.txt", "a//b.txt", "trailing/"] {
            await assertThrows(.unsafePath(path)) {
                try await original.rewrite(
                    to: directory.appendingPathComponent(UUID().uuidString),
                    removing: [],
                    adding: [ArchiveAddition(source: file, path: path)]
                )
            }
        }
    }

    func testDestinationMustNotExist() async throws {
        let directory = try makeTemporaryDirectory(self)
        let destination = directory.appendingPathComponent("exists.zip")
        try Data("keep".utf8).write(to: destination)
        let original = try await openFixture("basic")
        do {
            try await original.rewrite(to: destination, removing: [], adding: [])
            XCTFail("overwrote an existing file")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testRelocationBeyondFourGigabytesUsesZIP64() async throws {
        let original = try await openFixture("basic")
        let record = try XCTUnwrap(original.directoryRecords?[try original.entry("Holiday/notes.txt").id])
        let offset: UInt64 = 0x1_2345_6789
        let relocated = try ZIPRecordRelocator.relocate(record, to: offset)

        let parsed = ZIPCentralDirectory.parse(relocated, expectedCount: 1, baseOffset: 0, encoding: .automatic)
        XCTAssertEqual(parsed.warnings, [])
        let entry = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(entry.storageOffset, offset)
        XCTAssertEqual(entry.path, "Holiday/notes.txt")
        XCTAssertEqual(entry.crc32, try original.entry("Holiday/notes.txt").crc32)

        // And back below 4 GB, the ZIP64 field goes again.
        let back = try ZIPRecordRelocator.relocate(relocated, to: 100)
        XCTAssertEqual(back.count, record.count)
        let reparsed = ZIPCentralDirectory.parse(back, expectedCount: 1, baseOffset: 0, encoding: .automatic)
        XCTAssertEqual(reparsed.entries.first?.storageOffset, 100)
    }

    func testDOSDateClamping() {
        let early = ZIPEntryWriter.dosDateTime(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(early.date, 1 << 5 | 1) // 1980-01-01
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 13, minute: 45, second: 31))!
        let dos = ZIPEntryWriter.dosDateTime(date)
        XCTAssertEqual(ZIPHeaderParser.dosDate(date: dos.date, time: dos.time), date.addingTimeInterval(-1))
    }

    /// Checks the archive with Info-ZIP's `unzip -t` and Python's
    /// `zipfile`, where available, so we are not only agreeing with
    /// ourselves. With `original`, `unzip` must judge the copy exactly as
    /// it judges the original (some fixtures are deliberately unreadable).
    private func assertValidForOtherTools(
        _ url: URL,
        likeOriginal original: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        if FileManager.default.isExecutableFile(atPath: unzip.path) {
            let (status, output) = try run(unzip, ["-tqq", url.path])
            var expected: Int32 = 0
            if let original {
                expected = try run(unzip, ["-tqq", original.path]).0
                // The original's self-extractor stub is not copied, which
                // only removes unzip's warning about it.
                if expected == 1 && original.lastPathComponent == "prefixed.zip" { expected = 0 }
            }
            XCTAssertEqual(status, expected, "unzip -t: \(output)", file: file, line: line)
        }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        if FileManager.default.isExecutableFile(atPath: python.path) {
            let script = "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); print(len(z.infolist()))"
            let (status, output) = try run(python, ["-c", script, url.path])
            XCTAssertEqual(status, 0, "Python zipfile failed: \(output)", file: file, line: line)
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
