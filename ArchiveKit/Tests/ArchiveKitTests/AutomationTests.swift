import XCTest
@testable import ArchiveKit

final class AutomationTests: XCTestCase {
    func testListAcrossFormats() async throws {
        for (name, ext) in [("basic", "zip"), ("pax", "tar"), ("pax", "tar.gz"), ("default", "aar")] {
            let result = try await ArchiveAutomation.list(fixtureURL(name, extension: ext))
            XCTAssertFalse(result.items.isEmpty, "\(name).\(ext)")
            XCTAssertEqual(result.schema, 1)
        }
        let zip = try await ArchiveAutomation.list(fixtureURL("basic"))
        let big = try XCTUnwrap(zip.items.first { $0.path == "Holiday/big.txt" })
        XCTAssertEqual(big.type, "file")
        XCTAssertEqual(big.size, 300_000)
        XCTAssertEqual(big.method, "Deflate")
        XCTAssertNotNil(big.modified)
    }

    func testMatchingUsesTheApplicationsSearchSyntax() async throws {
        let url = fixtureURL("basic")
        let byExtension = try await ArchiveAutomation.list(url, matching: "*.txt")
        XCTAssertTrue(byExtension.items.allSatisfy { $0.path.hasSuffix(".txt") })
        XCTAssertFalse(byExtension.items.isEmpty)
        // A matching folder brings everything inside it.
        let folder = try await ArchiveAutomation.list(url, matching: "Photos/")
        XCTAssertTrue(folder.items.contains { $0.path == "Holiday/Photos/beach.txt" })
        let none = try await ArchiveAutomation.list(url, matching: "no-such-thing-xyz")
        XCTAssertTrue(none.items.isEmpty)
        let blank = try await ArchiveAutomation.list(url, matching: "  ")
        let everything = try await ArchiveAutomation.list(url)
        XCTAssertEqual(blank.items.count, everything.items.count)
    }

    func testExtractAllAndMatching() async throws {
        let all = try makeTemporaryDirectory(self).appendingPathComponent("out")
        let result = try await ArchiveAutomation.extract(fixtureURL("basic"), to: all)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertTrue(result.extracted.contains("Holiday/notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: all.appendingPathComponent("Holiday/notes.txt").path))

        let some = try makeTemporaryDirectory(self).appendingPathComponent("some")
        let matched = try await ArchiveAutomation.extract(fixtureURL("basic"), to: some, matching: "notes.txt")
        XCTAssertEqual(matched.extracted.filter { !$0.hasSuffix("/") }, ["Holiday/notes.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: some.appendingPathComponent("README").path))
    }

    func testExtractReportsRefusedItemsInsteadOfWritingThem() async throws {
        let folder = try makeTemporaryDirectory(self).appendingPathComponent("evil")
        let result = try await ArchiveAutomation.extract(fixtureURL("traversal"), to: folder)
        XCTAssertEqual(Set(result.failures.map(\.kind)), ["unsafePath"])
        XCTAssertEqual(result.extracted, ["good.txt"])
    }

    func testConflictPolicies() async throws {
        let folder = try makeTemporaryDirectory(self).appendingPathComponent("c")
        let url = fixtureURL("pax", extension: "tar")
        _ = try await ArchiveAutomation.extract(url, to: folder, matching: "run.sh")
        let skipped = try await ArchiveAutomation.extract(url, to: folder, matching: "run.sh", conflict: .skip)
        XCTAssertEqual(skipped.skipped, ["bin/run.sh"])
        let both = try await ArchiveAutomation.extract(url, to: folder, matching: "run.sh", conflict: .keepBoth)
        XCTAssertEqual(both.extracted, ["bin/run 2.sh"])
        let failed = try await ArchiveAutomation.extract(url, to: folder, matching: "run.sh", conflict: .fail)
        XCTAssertEqual(failed.failures.map(\.kind), ["destinationExists"])
    }

    func testVerify() async throws {
        let good = try await ArchiveAutomation.verify(fixtureURL("basic"))
        XCTAssertTrue(good.intact)
        XCTAssertGreaterThan(good.verified, 0)
        let bad = try await ArchiveAutomation.verify(fixtureURL("bad_crc"))
        XCTAssertFalse(bad.intact)
        XCTAssertEqual(bad.damaged.map(\.kind), ["checksumMismatch"])
    }

    func testVerifyWithAndWithoutPassword() async throws {
        let locked = try await ArchiveAutomation.verify(fixtureURL("aes256"))
        XCTAssertTrue(locked.intact)
        XCTAssertEqual(locked.notChecked.count, 4)
        XCTAssertEqual(Set(locked.notChecked.map(\.kind)), ["passwordRequired"])
        let opened = try await ArchiveAutomation.verify(fixtureURL("aes256"), options: .init(password: "secret"))
        XCTAssertTrue(opened.notChecked.isEmpty)
        XCTAssertEqual(opened.verified, 4)
        let wrong = try await ArchiveAutomation.verify(fixtureURL("aes256"), options: .init(password: "wrong"))
        XCTAssertEqual(wrong.notChecked.count, 4)
    }

    func testSafety() async throws {
        let evil = try await ArchiveAutomation.safety(fixtureURL("traversal"))
        XCTAssertFalse(evil.clean)
        XCTAssertEqual(Set(evil.blocked.map(\.kind)), ["unsafePath"])
        XCTAssertTrue(evil.blocked.allSatisfy { $0.severity == "blocked" })
        let fine = try await ArchiveAutomation.safety(fixtureURL("mixed"))
        XCTAssertTrue(fine.clean)
        let scripts = try await ArchiveAutomation.safety(fixtureURL("pax", extension: "tar"))
        XCTAssertEqual(scripts.cautions.map(\.path), ["bin/run.sh"])
    }

    func testChecksums() async throws {
        let result = try await ArchiveAutomation.checksums(fixtureURL("pax", extension: "tar"), matching: "hello.txt")
        XCTAssertEqual(result.items.count, 2) // hello.txt and its hard link
        XCTAssertEqual(Set(result.items.map(\.sha256)).count, 1)
        XCTAssertEqual(result.items[0].sha256.count, 64)
        XCTAssertTrue(result.listing.hasSuffix("\n"))
        XCTAssertTrue(result.listing.contains("  hello.txt\n"))
        let locked = try await ArchiveAutomation.checksums(fixtureURL("aes256"))
        XCTAssertTrue(locked.items.isEmpty)
        XCTAssertEqual(locked.skipped.count, 4)
    }

    func testResultsEncodeToStableJSON() async throws {
        let result = try await ArchiveAutomation.list(fixtureURL("basic"), matching: "notes.txt")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try XCTUnwrap(String(data: try encoder.encode(result), encoding: .utf8))
        XCTAssertTrue(json.hasPrefix("{\"archive\":"))
        for key in ["\"schema\":1", "\"items\":[", "\"path\":\"Holiday/notes.txt\"", "\"compressedSize\":", "\"warnings\":[]"] {
            XCTAssertTrue(json.contains(key), key)
        }
    }

    func testUnsupportedFormatsThrow() async throws {
        do {
            _ = try await ArchiveAutomation.list(fixtureURL("fake", extension: "7z"))
            XCTFail("expected an error")
        } catch let error as ArchiveError {
            XCTAssertEqual(error.logKind, "unsupportedFormat")
        }
    }
}
