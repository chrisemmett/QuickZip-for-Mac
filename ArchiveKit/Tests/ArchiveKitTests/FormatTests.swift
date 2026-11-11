import XCTest
@testable import ArchiveKit

/// tar, tar.gz, tar.xz and Apple Archive (HLD §18.4, Phase 6). Fixtures come
/// from Python's tarfile, the system tar and aa, gzip and xz; see
/// Scripts/make_fixtures.py.
final class TarTests: XCTestCase {
    private let longDirectory = [String(repeating: "a", count: 40), String(repeating: "b", count: 40), String(repeating: "c", count: 40)].joined(separator: "/")

    private func open(_ name: String, _ ext: String, compression: TarArchive.Compression) async throws -> TarArchive {
        try await TarArchive.open(fixtureURL(name, extension: ext), compression: compression)
    }

    private func bigText() async throws -> Data {
        let zip = try await openFixture("lzma")
        return try await zip.contents(of: zip.entry("big.txt"))
    }

    private func check(_ archive: TarArchive, links: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws {
        let paths = Set(archive.entries.map(\.path))
        for expected in ["docs", "docs/readme.md", "docs/big.txt", "bin", "bin/run.sh", "hello.txt", "empty.txt",
                         longDirectory + "/file.txt", "Ünïcødé/日本語.txt"] {
            XCTAssertTrue(paths.contains(expected), "missing \(expected)", file: file, line: line)
        }
        let hello = try await archive.contents(of: archive.entry("hello.txt"))
        XCTAssertEqual(String(decoding: hello, as: UTF8.self), "Hello, tar!\n", file: file, line: line)
        let big = try await archive.contents(of: archive.entry("docs/big.txt"))
        let reference = try await bigText()
        XCTAssertEqual(big, reference, file: file, line: line)
        let empty = try await archive.contents(of: archive.entry("empty.txt"))
        XCTAssertTrue(empty.isEmpty, file: file, line: line)
        let long = try await archive.contents(of: archive.entry(longDirectory + "/file.txt"))
        XCTAssertEqual(String(decoding: long, as: UTF8.self), "a long path\n", file: file, line: line)
        let unicode = try await archive.contents(of: archive.entry("Ünïcødé/日本語.txt"))
        XCTAssertEqual(String(decoding: unicode, as: UTF8.self), "unicode names\n", file: file, line: line)
        XCTAssertEqual(try archive.entry("bin/run.sh").posixPermissions, 0o755, file: file, line: line)
        XCTAssertEqual(try archive.entry("docs").type, .directory, file: file, line: line)
        if links {
            let link = try archive.entry("link-to-hello")
            XCTAssertEqual(link.type, .symlink, file: file, line: line)
            let target = try await archive.contents(of: link)
            XCTAssertEqual(String(decoding: target, as: UTF8.self), "hello.txt", file: file, line: line)
        }
    }

    func testPaxGNUAndUstar() async throws {
        for name in ["pax", "gnu", "ustar"] {
            let archive = try await open(name, "tar", compression: .none)
            XCTAssertEqual(archive.warnings, [], name)
            try await check(archive)
        }
    }

    func testHardLinksShareTheirTargetsData() async throws {
        let archive = try await open("pax", "tar", compression: .none)
        let hard = try archive.entry("hard-hello.txt")
        XCTAssertEqual(hard.type, .file)
        XCTAssertEqual(hard.uncompressedSize, 12)
        let data = try await archive.contents(of: hard)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Hello, tar!\n")
    }

    func testTarMadeBySystemTool() async throws {
        let plain = try await open("bsd", "tar", compression: .none)
        try await check(plain)
        let gzipped = try await open("bsd", "tar.gz", compression: .gzip)
        try await check(gzipped)
        XCTAssertEqual(gzipped.entries.map(\.path), plain.entries.map(\.path))
    }

    func testGzipXzAndMultiMemberStreams() async throws {
        let gzip = try await open("pax", "tar.gz", compression: .gzip)
        try await check(gzip)
        XCTAssertEqual(try gzip.entry("hello.txt").compressionMethod, .wholeArchive("gzip"))
        let multi = try await open("multi", "tar.gz", compression: .gzip)
        try await check(multi)
        let xz = try await open("pax", "tar.xz", compression: .xz)
        try await check(xz)
        let blocks = try await open("blocks", "tar.xz", compression: .xz)
        try await check(blocks)
    }

    func testCompressedAndPlainAgree() async throws {
        let plain = try await open("pax", "tar", compression: .none)
        let gz = try await open("pax", "tar.gz", compression: .gzip)
        XCTAssertEqual(plain.entries.map(\.path), gz.entries.map(\.path))
        XCTAssertEqual(plain.entries.map(\.uncompressedSize), gz.entries.map(\.uncompressedSize))
        XCTAssertEqual(plain.entries.map(\.posixPermissions), gz.entries.map(\.posixPermissions))
    }

    func testProgressIsReportedAndOpeningCanBeCancelled() async throws {
        let box = ProgressBox()
        _ = try await TarArchive.open(fixtureURL("pax", extension: "tar.gz"), compression: .gzip) { box.add($0) }
        let values = box.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())

        let task = Task { try await TarArchive.open(fixtureURL("pax", extension: "tar.gz"), compression: .gzip) }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            return
        }
        // It may finish before the cancellation is seen; that is not a failure.
    }

    func testTruncatedAndDamagedArchivesKeepWhatCanBeRead() async throws {
        let truncated = try await open("truncated", "tar", compression: .none)
        XCTAssertFalse(truncated.warnings.isEmpty)
        XCTAssertFalse(truncated.entries.isEmpty)
        let readme = try await truncated.string("docs/readme.md")
        XCTAssertTrue(readme.hasPrefix("# Readme"))

        let bad = try await open("badheader", "tar", compression: .none)
        XCTAssertFalse(bad.warnings.isEmpty)
        XCTAssertGreaterThan(bad.entries.count, 0)

        let gz = try await open("truncated", "tar.gz", compression: .gzip)
        XCTAssertFalse(gz.warnings.isEmpty)
        XCTAssertFalse(gz.entries.isEmpty)
    }

    func testNotATar() async throws {
        do {
            _ = try await open("notatar", "gz", compression: .gzip)
            XCTFail("expected an error")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .notAnArchive)
        }
    }

    func testEmptyTar() async throws {
        let archive = try await open("empty", "tar", compression: .none)
        XCTAssertTrue(archive.entries.isEmpty)
    }

    func testSpecialFilesAreNotListed() async throws {
        let archive = try await open("special", "tar", compression: .none)
        XCTAssertEqual(archive.entries.map(\.path), ["kept.txt"])
        XCTAssertTrue(archive.warnings.contains { $0.contains("2") })
    }

    func testExtractionThroughTheSharedExtractor() async throws {
        let archive = try await open("pax", "tar.gz", compression: .gzip)
        let folder = try makeTemporaryDirectory(self)
        let result = try await ArchiveExtractor(destination: folder).extract(archive.entries, from: archive)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.error))")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), "Hello, tar!\n")
        let script = folder.appendingPathComponent("bin/run.sh")
        XCTAssertEqual(try posixPermissions(at: script) & 0o777, 0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link-to-hello").path), "hello.txt")
    }

    func testTraversalAndEscapingLinksAreStillRefused() async throws {
        // A tar with "../evil" and a link out of the folder.
        var bytes = Data()
        func header(_ name: String, type: UInt8, link: String = "", size: Int = 0) -> Data {
            var block = [UInt8](repeating: 0, count: 512)
            for (i, b) in name.utf8.enumerated() { block[i] = b }
            for (i, b) in String(format: "%07o", 0o644).utf8.enumerated() { block[100 + i] = b }
            for (i, b) in String(format: "%011o", size).utf8.enumerated() { block[124 + i] = b }
            block[156] = type
            for (i, b) in link.utf8.enumerated() { block[157 + i] = b }
            for (i, b) in "ustar\0".utf8.enumerated() { block[257 + i] = b }
            for index in 148..<156 { block[index] = 0x20 }
            let sum = block.reduce(0) { $0 + Int($1) }
            for (i, b) in String(format: "%06o", sum).utf8.enumerated() { block[148 + i] = b }
            block[154] = 0; block[155] = 0x20
            return Data(block)
        }
        bytes += header("../evil.txt", type: UInt8(ascii: "0"), size: 4) + Data("evil".utf8) + Data(count: 508)
        bytes += header("escape", type: UInt8(ascii: "2"), link: "../../../../tmp")
        bytes += header("fine.txt", type: UInt8(ascii: "0"), size: 2) + Data("ok".utf8) + Data(count: 510)
        bytes += Data(count: 1024)
        let url = try makeTemporaryDirectory(self).appendingPathComponent("evil.tar")
        try bytes.write(to: url)

        let archive = try await TarArchive.open(url, compression: .none)
        XCTAssertEqual(archive.entries.map(\.path), ["../evil.txt", "escape", "fine.txt"])
        let report = await archive.safetyReport()
        XCTAssertEqual(Set(report.blocked.map(\.entry.path)), ["../evil.txt", "escape"])

        let folder = try makeTemporaryDirectory(self)
        let result = try await ArchiveExtractor(destination: folder).extract(archive.entries, from: archive)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("fine.txt"), encoding: .utf8), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    func testDecompressionBombIsRefused() async throws {
        // 64 MiB of zeros compresses to a few KiB with xz (DEFLATE cannot
        // pass about 1000:1, which is why that ratio is allowed): far over the limit.
        let zeros = Data(count: 64 << 20)
        var tar = Data()
        var block = [UInt8](repeating: 0, count: 512)
        for (i, b) in "big.bin".utf8.enumerated() { block[i] = b }
        for (i, b) in String(format: "%011o", zeros.count).utf8.enumerated() { block[124 + i] = b }
        block[156] = UInt8(ascii: "0")
        for (i, b) in "ustar\0".utf8.enumerated() { block[257 + i] = b }
        for index in 148..<156 { block[index] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        for (i, b) in String(format: "%06o", sum).utf8.enumerated() { block[148 + i] = b }
        block[154] = 0; block[155] = 0x20
        tar += Data(block) + zeros + Data(count: 1024)
        let dir = try makeTemporaryDirectory(self)
        let tarURL = dir.appendingPathComponent("bomb.tar")
        try tar.write(to: tarURL)
        let xz = dir.appendingPathComponent("bomb.tar.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xz", "-k", "-9", tarURL.path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: xz.path), "xz is not installed")

        let limits = ArchiveLimits(compressionRatioThreshold: 1 << 20)
        do {
            _ = try await TarArchive.open(xz, compression: .xz, limits: limits)
            XCTFail("expected the bomb to be refused")
        } catch let error as ArchiveError {
            if case .exceedsLimits = error {} else { XCTFail("\(error)") }
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class AppleArchiveTests: XCTestCase {
    func testAllCompressionVariants() async throws {
        var lists: [[String]] = []
        for name in ["default", "raw", "lzma"] {
            let archive = try await AppleArchiveProvider.open(fixtureURL(name, extension: "aar"))
            lists.append(archive.entries.map(\.path))
            let hello = try await archive.string("hello.txt")
            XCTAssertEqual(hello, "Hello, tar!\n", name)
            let big = try await archive.contents(of: archive.entry("docs/big.txt"))
            let zip = try await openFixture("lzma")
            let reference = try await zip.contents(of: zip.entry("big.txt"))
            XCTAssertEqual(big, reference, name)
            XCTAssertEqual(try archive.entry("bin/run.sh").posixPermissions, 0o755, name)
            XCTAssertEqual(try archive.entry("docs").type, .directory, name)
            let link = try archive.entry("link-to-hello")
            XCTAssertEqual(link.type, .symlink)
            let target = try await archive.contents(of: link)
            XCTAssertEqual(String(decoding: target, as: UTF8.self), "hello.txt")
            XCTAssertNotNil(try archive.entry("hello.txt").modificationDate)
        }
        XCTAssertEqual(lists[0], lists[1])
        XCTAssertEqual(lists[1], lists[2])
    }

    func testExtraction() async throws {
        let archive = try await AppleArchiveProvider.open(fixtureURL("default", extension: "aar"))
        let folder = try makeTemporaryDirectory(self)
        let result = try await ArchiveExtractor(destination: folder).extract(archive.entries, from: archive)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.error))")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("hello.txt"), encoding: .utf8), "Hello, tar!\n")
    }

    func testGarbageIsNotAnArchive() async throws {
        let url = try makeTemporaryDirectory(self).appendingPathComponent("junk.aar")
        try Data("AA01 not really".utf8).write(to: url)
        do {
            _ = try await AppleArchiveProvider.open(url)
            XCTFail("expected an error")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .notAnArchive)
        }
    }
}

final class FormatDetectionTests: XCTestCase {
    func testDetection() throws {
        let expectations: [(String, String, ArchiveFormat)] = [
            ("basic", "zip", .zip), ("prefixed", "zip", .zip), ("empty", "zip", .zip),
            ("pax", "tar", .tar), ("gnu", "tar", .tar), ("ustar", "tar", .tar), ("bsd", "tar", .tar),
            ("pax", "tar.gz", .tarGzip), ("pax", "tar.xz", .tarXz),
            ("default", "aar", .appleArchive), ("raw", "aar", .appleArchive), ("lzma", "aar", .appleArchive),
            ("fake", "7z", .unsupported("7z")), ("fake", "rar", .unsupported("RAR")), ("fake", "bz2", .unsupported("bzip2")),
        ]
        for (name, ext, expected) in expectations {
            XCTAssertEqual(try ArchiveFormat.detect(at: fixtureURL(name, extension: ext)), expected, "\(name).\(ext)")
        }
    }

    func testOpenerDispatchesAndExplainsUnsupportedFormats() async throws {
        for (name, ext) in [("basic", "zip"), ("pax", "tar"), ("pax", "tar.gz"), ("pax", "tar.xz"), ("default", "aar")] {
            let archive = try await ArchiveOpener.open(fixtureURL(name, extension: ext))
            let entries = await archive.entries
            XCTAssertFalse(entries.isEmpty, "\(name).\(ext)")
        }
        for (ext, format) in [("7z", "7z"), ("rar", "RAR"), ("bz2", "bzip2")] {
            do {
                _ = try await ArchiveOpener.open(fixtureURL("fake", extension: ext))
                XCTFail("expected an error")
            } catch let error as ArchiveError {
                XCTAssertEqual(error, .unsupportedFormat(path: "fake.\(ext)", format: format))
                XCTAssertTrue(error.errorDescription?.contains("ZIP, tar") ?? false)
            }
        }
    }
}
