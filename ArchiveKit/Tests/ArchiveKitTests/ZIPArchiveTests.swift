import Foundation
import XCTest
@testable import ArchiveKit

final class ZIPArchiveTests: XCTestCase {
    // MARK: Listing

    func testListsBasicArchive() async throws {
        let archive = try await openFixture("basic")
        XCTAssertEqual(archive.entries.map(\.path), [
            "Holiday", "Holiday/Photos", "Holiday/notes.txt", "Holiday/Photos/beach.txt",
            "Holiday/stored.txt", "Holiday/empty.txt", "Holiday/run.sh", "Holiday/setuid",
            "Holiday/big.txt", "README",
        ])
        XCTAssertEqual(archive.entries.map(\.id), Array(0..<10))
        XCTAssertTrue(archive.warnings.isEmpty)

        let folder = try archive.entry("Holiday")
        XCTAssertEqual(folder.type, .directory)
        XCTAssertEqual(folder.name, "Holiday")

        let notes = try archive.entry("Holiday/notes.txt")
        XCTAssertEqual(notes.type, .file)
        XCTAssertEqual(notes.name, "notes.txt")
        XCTAssertEqual(notes.pathExtension, "txt")
        XCTAssertEqual(notes.compressionMethod, .deflate)
        XCTAssertEqual(notes.uncompressedSize, 14)
        XCTAssertEqual(notes.crc32, CRC32.checksum(Data("Hello, world!\n".utf8)))
        XCTAssertEqual(notes.posixPermissions, 0o644)
        XCTAssertFalse(notes.isEncrypted)
        XCTAssertTrue(notes.isReadable)

        XCTAssertEqual(try archive.entry("Holiday/stored.txt").compressionMethod, .stored)
        XCTAssertEqual(try archive.entry("Holiday/run.sh").posixPermissions, 0o755)
        XCTAssertEqual(try archive.entry("Holiday/setuid").posixPermissions, 0o4755)
    }

    func testDOSDateIsInterpretedAsLocalTime() async throws {
        let archive = try await openFixture("basic")
        let date = try XCTUnwrap(try archive.entry("README").modificationDate)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components, DateComponents(year: 2024, month: 3, day: 15, hour: 10, minute: 30))
    }

    func testEmptyArchive() async throws {
        let archive = try await openFixture("empty")
        XCTAssertTrue(archive.entries.isEmpty)
        XCTAssertTrue(archive.warnings.isEmpty)
    }

    func testZIP64() async throws {
        let archive = try await openFixture("zip64")
        XCTAssertEqual(archive.entries.map(\.path), ["one.txt", "dir/two.txt"])
        XCTAssertEqual(try archive.entry("dir/two.txt").uncompressedSize, 3000)
        let one = try await archive.string("one.txt")
        XCTAssertEqual(one, "Hello, world!\n")
        let two = try await archive.string("dir/two.txt")
        XCTAssertEqual(two, String(repeating: "two", count: 1000))
    }

    func testDataDescriptors() async throws {
        let archive = try await openFixture("data_descriptor")
        XCTAssertEqual(archive.entries.map(\.path), ["streamed.txt", "second.txt"])
        let second = try await archive.string("second.txt")
        XCTAssertEqual(second, "Hello, world!\n")
        let streamed = try await archive.contents(of: try archive.entry("streamed.txt"))
        XCTAssertEqual(streamed.count, 5000)
    }

    func testPrefixedSelfExtractingArchive() async throws {
        let archive = try await openFixture("prefixed")
        XCTAssertEqual(archive.entries.map(\.path), ["inside.txt", "folder/more.txt"])
        let more = try await archive.string("folder/more.txt")
        XCTAssertEqual(more, "more")
    }

    func testRealWorldProducers() async throws {
        let python = try await openFixture("python_zipfile")
        XCTAssertEqual(python.entries.map(\.path), ["py/hello.txt", "py/folder", "py/text.txt"])
        XCTAssertEqual(try python.entry("py/folder").type, .directory)
        let pythonReport = try await python.verify()
        XCTAssertEqual(pythonReport.verifiedCount, 2)

        let infozip = try await openFixture("infozip")
        XCTAssertEqual(try infozip.entry("Project/main-link.c").type, .symlink)
        XCTAssertEqual(try infozip.entry("Project/build.sh").posixPermissions, 0o755)
        let link = try await infozip.string("Project/main-link.c")
        XCTAssertEqual(link, "src/main.c")
        // Info-ZIP's extended timestamp extra field is UTC.
        XCTAssertEqual(try infozip.entry("Project/build.sh").modificationDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Names

    func testFilenameEncodings() async throws {
        let archive = try await openFixture("names")
        let paths = archive.entries.map(\.path)
        XCTAssertEqual(paths[0], "Ünïcødé/日本語.txt", "UTF-8 flag")
        XCTAssertEqual(paths[1], "café.txt", "CP437 fallback")
        XCTAssertEqual(paths[2], "naïve.txt", "Info-ZIP Unicode Path extra field")
        XCTAssertEqual(paths[4], "win/path/file.txt", "backslashes become separators")
    }

    func testFilenameEncodingOverride() async throws {
        guard String(bytes: [0x83, 0x65], encoding: .shiftJIS) != nil else {
            throw XCTSkip("Foundation on this platform cannot decode Shift-JIS")
        }
        let archive = try await openFixture("names", options: ZIPArchiveOptions(filenameEncoding: .encoding(.shiftJIS)))
        XCTAssertEqual(archive.entries[3].path, "Shift/テスト.txt")
        // Names marked UTF-8 are unaffected by the override.
        XCTAssertEqual(archive.entries[0].path, "Ünïcødé/日本語.txt")
    }

    // MARK: Reading

    func testReadsStoredAndDeflatedEntries() async throws {
        let archive = try await openFixture("basic")
        let notes = try await archive.string("Holiday/notes.txt")
        XCTAssertEqual(notes, "Hello, world!\n")
        let stored = try await archive.string("Holiday/stored.txt")
        XCTAssertEqual(stored, "not compressed\n")
        let beach = try await archive.string("Holiday/Photos/beach.txt")
        XCTAssertEqual(beach, String(repeating: "sand ", count: 100))
        let empty = try await archive.contents(of: try archive.entry("Holiday/empty.txt"))
        XCTAssertTrue(empty.isEmpty)
        let big = try await archive.contents(of: try archive.entry("Holiday/big.txt"))
        XCTAssertEqual(big.count, 300_000)
        let directory = try await archive.contents(of: try archive.entry("Holiday"))
        XCTAssertTrue(directory.isEmpty)
    }

    func testStreamsLargeEntriesInBoundedChunks() async throws {
        let archive = try await openFixture("zeros")
        let entry = try archive.entry("zeros.bin")
        var total = 0
        var largestChunk = 0
        try await archive.read(entry) { chunk in
            total += chunk.count
            largestChunk = max(largestChunk, chunk.count)
            XCTAssertTrue(chunk.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(total, 16 << 20)
        XCTAssertLessThanOrEqual(largestChunk, 256 * 1024)
    }

    func testMixedStoredAndDynamicBlocks() async throws {
        let archive = try await openFixture("mixed")
        let report = try await archive.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertTrue(report.isIntact)
    }

    func testReadingIsCancellable() async throws {
        let archive = try await openFixture("zeros")
        let entry = try archive.entry("zeros.bin")
        let task = Task {
            try await archive.read(entry) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
    }

    func testRejectsEntriesFromAnotherArchive() async throws {
        let basic = try await openFixture("basic")
        let other = try await openFixture("zip64")
        let foreign = try other.entry("one.txt")
        await assertThrows(.unknownEntry(path: "one.txt")) { try await basic.contents(of: foreign) }
    }

    // MARK: Unsupported and encrypted entries

    func testEncryptedEntriesNeedAPassword() async throws {
        let archive = try await openFixture("encrypted")
        let secret = try archive.entry("secret.txt")
        XCTAssertTrue(secret.isEncrypted)
        XCTAssertTrue(secret.needsPassword)
        let aes = try archive.entry("aes.txt")
        XCTAssertEqual(aes.encryption, .winZipAES(strength: .aes256, version: 2))
        XCTAssertEqual(aes.compressionMethod, .deflate, "AES entries report their real method")
        XCTAssertTrue(aes.isReadable)
        XCTAssertFalse(try archive.entry("public.txt").isEncrypted)

        await assertThrows(.passwordRequired(path: "secret.txt")) { try await archive.string("secret.txt") }
        let text = try await archive.string("public.txt")
        XCTAssertEqual(text, "Hello, world!\n")
    }

    func testUnsupportedMethodsAreListedWithSpecificErrors() async throws {
        let archive = try await openFixture("unsupported_methods")
        XCTAssertEqual(archive.entries.map(\.compressionMethod), [.deflate64, .bzip2, .zstd, .deflate])
        await assertThrows(.unsupportedCompressionMethod(path: "bzip2.bin", method: .bzip2)) {
            try await archive.string("bzip2.bin")
        }
        XCTAssertEqual(
            ArchiveError.unsupportedCompressionMethod(path: "bzip2.bin", method: .bzip2).errorDescription,
            "“bzip2.bin” is compressed with bzip2, which is not supported."
        )
        let report = try await archive.verify()
        XCTAssertEqual(report.unverifiable.map(\.path), ["bzip2.bin", "zstd.bin"])
        XCTAssertEqual(report.verifiedCount, 1)
        // Deflate64 is decoded now, and the fixture's payload is not a valid stream.
        XCTAssertEqual(report.failures.map(\.entry.path), ["deflate64.bin"])
    }

    // MARK: Damaged and malicious archives

    func testChecksumMismatch() async throws {
        let archive = try await openFixture("bad_crc")
        let entry = try archive.entry("bad.txt")
        await assertThrows(.checksumMismatch(path: "bad.txt", expected: 0xDEAD_BEEF, actual: CRC32.checksum(Data("Hello, world!\n".utf8)))) {
            try await archive.contents(of: entry)
        }
        let report = try await archive.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(report.failures.map(\.entry.path), ["bad.txt"])
    }

    func testDamagedDirectoryRecoversLeadingEntries() async throws {
        let archive = try await openFixture("damaged_directory")
        XCTAssertEqual(archive.entries.map(\.path), ["first.txt", "second.txt"])
        XCTAssertEqual(archive.warnings.count, 1)
        let second = try await archive.string("second.txt")
        XCTAssertEqual(second, "2")
    }

    func testTruncatedArchiveRecoversCompleteEntries() async throws {
        let archive = try await openFixture("truncated")
        XCTAssertEqual(archive.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertEqual(archive.warnings.count, 1)
        let report = try await archive.verify()
        XCTAssertEqual(report.verifiedCount, 2)
    }

    func testDeclaredSizesAreEnforced() async throws {
        let archive = try await openFixture("lying_size")
        let bomb = try archive.entry("bomb.txt")
        XCTAssertEqual(bomb.uncompressedSize, 1 << 41)
        await assertThrows(.exceedsLimits(
            path: "bomb.txt",
            reason: "its declared size (2199023255552 bytes) is larger than the 1099511627776-byte limit"
        )) { try await archive.contents(of: bomb) }

        // More output than declared stops the stream.
        let short = try archive.entry("short.txt")
        do {
            _ = try await archive.contents(of: short)
            XCTFail("expected a size mismatch")
        } catch ArchiveError.sizeMismatch(let path, let expected, _) {
            XCTAssertEqual(path, "short.txt")
            XCTAssertEqual(expected, 10)
        }
    }

    func testCompressionRatioLimit() async throws {
        let limits = ArchiveLimits(maximumCompressionRatio: 100, compressionRatioThreshold: 1 << 20)
        let archive = try await openFixture("zeros", options: ZIPArchiveOptions(limits: limits))
        let entry = try archive.entry("zeros.bin")
        do {
            _ = try await archive.contents(of: entry)
            XCTFail("expected the ratio limit to apply")
        } catch ArchiveError.exceedsLimits(let path, _) {
            XCTAssertEqual(path, "zeros.bin")
        }
    }

    func testOverlappingEntriesAreRefused() async throws {
        let archive = try await openFixture("overlapping")
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(archive.warnings.count, 1)
        await assertThrows(.malformed("“a.txt” overlaps another item")) { try await archive.string("a.txt") }
    }

    func testOutOfRangeOffsets() async throws {
        let archive = try await openFixture("bad_offset")
        await assertThrows(.malformed("a structure points beyond the end of the file")) {
            try await archive.string("far.txt")
        }
    }

    func testNotAnArchive() async throws {
        let directory = try makeTemporaryDirectory(self)
        let tiny = directory.appendingPathComponent("tiny.zip")
        try Data("PK".utf8).write(to: tiny)
        await assertThrows(.notAnArchive) { try await ZIPArchive.open(tiny) }

        let text = directory.appendingPathComponent("text.zip")
        try Data(repeating: 0x41, count: 100_000).write(to: text)
        await assertThrows(.notAnArchive) { try await ZIPArchive.open(text) }
    }
}
