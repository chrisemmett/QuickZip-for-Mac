import CryptoKit
import XCTest
@testable import ArchiveKit

final class SafetyTests: XCTestCase {
    private func kinds(_ report: ArchiveSafetyReport) -> [String: Set<SafetyFinding.Kind>] {
        var result: [String: Set<SafetyFinding.Kind>] = [:]
        for finding in report.findings { result[finding.entry.path, default: []].insert(finding.kind) }
        return result
    }

    private func entry(_ path: String, id: Int = 0, type: EntryType = .file, size: UInt64 = 10) -> ArchiveEntry {
        ArchiveEntry(id: id, path: path, type: type, compressedSize: size, uncompressedSize: size,
                     modificationDate: nil, compressionMethod: .stored, crc32: nil)
    }

    func testPathTraversalIsBlocked() async throws {
        let archive = try await openFixture("traversal")
        let report = await archive.safetyReport()
        let found = kinds(report)
        for path in ["../../evil.txt", "/absolute.txt", "safe/../../escape.txt", "C:/windows.txt"] {
            XCTAssertEqual(found[path], [.unsafePath], path)
        }
        XCTAssertNil(found["good.txt"])
        XCTAssertTrue(report.findings.allSatisfy { $0.severity == .blocked })
    }

    func testSymlinksEscapingTheDestinationAreBlocked() async throws {
        let archive = try await openFixture("symlinks")
        let report = await archive.safetyReport()
        let found = kinds(report)
        XCTAssertEqual(found["escape"], [.unsafeSymlink])
        XCTAssertEqual(found["absolute-link"], [.unsafeSymlink])
        XCTAssertNil(found["dir/link"], "a link inside the destination is fine")
    }

    func testSymlinkTargetIsReported() async throws {
        let archive = try await openFixture("symlinks")
        let report = await archive.safetyReport()
        let finding = try XCTUnwrap(report.findings.first { $0.entry.path == "absolute-link" })
        XCTAssertEqual(finding.detail, "/etc/passwd")
    }

    func testZIPBombIndicatorsAreBlocked() async throws {
        let lying = try await openFixture("lying_size")
        let lyingReport = await lying.safetyReport()
        XCTAssertEqual(kinds(lyingReport)["bomb.txt"], [.exceedsLimits])
        let overlapping = try await openFixture("overlapping")
        let overlappingReport = await overlapping.safetyReport()
        let found = kinds(overlappingReport)
        XCTAssertEqual(found["a.txt"], [.overlappingData])
        XCTAssertEqual(found["b.txt"], [.overlappingData])
    }

    func testOrdinaryArchivesHaveNoFindings() async throws {
        for name in ["mixed", "implicit_dirs", "zip64", "data_descriptor"] {
            let archive = try await openFixture(name)
            let report = await archive.safetyReport()
            XCTAssertTrue(report.isEmpty, "\(name): \(report.findings.map(\.kind))")
        }
    }

    func testDeceptiveNamesAndExecutables() async {
        let entries = [
            entry("invoice.pdf.app", id: 0, type: .directory),
            entry("invoice.pdf.app/Contents/MacOS/run", id: 1),
            entry("photo.jpg.exe", id: 2),
            entry("setup.sh", id: 3),
            entry("notes.txt", id: 4),
            entry("archive.tar.gz", id: 5),
            entry("report\u{202E}fdp.exe", id: 6),
            entry("a/b.v2.pkg", id: 7),
            entry("__MACOSX/._setup.sh", id: 8),
            entry("Tool.app/Contents/Info.plist", id: 9),
            entry("Tool.app/Contents/Resources/x.sh", id: 10),
        ]
        let report = await ArchiveSafetyAnalyzer.analyze(entries: entries, limits: ArchiveLimits())
        let found = kinds(report)
        XCTAssertEqual(found["invoice.pdf.app"], [.applicationBundle, .doubleExtension])
        XCTAssertNil(found["invoice.pdf.app/Contents/MacOS/run"], "the bundle is reported once")
        XCTAssertEqual(found["photo.jpg.exe"], [.doubleExtension])
        XCTAssertEqual(found["setup.sh"], [.executable])
        XCTAssertNil(found["notes.txt"])
        XCTAssertNil(found["archive.tar.gz"])
        XCTAssertTrue(found["report\u{202E}fdp.exe"]?.contains(.deceptiveCharacters) ?? false)
        XCTAssertEqual(found["a/b.v2.pkg"], [.executable])
        XCTAssertNil(found["__MACOSX/._setup.sh"])
        XCTAssertEqual(found["Tool.app/Contents/Info.plist"], [.applicationBundle])
        XCTAssertNil(found["Tool.app/Contents/Resources/x.sh"])
        XCTAssertEqual(report.findings.first?.severity, .caution)
    }

    func testFindingsAreCappedAndOrdered() async {
        let entries = (0..<(ArchiveSafetyAnalyzer.findingLimit + 50)).map { entry("s\($0).sh", id: $0) }
        let report = await ArchiveSafetyAnalyzer.analyze(entries: entries, limits: ArchiveLimits())
        XCTAssertEqual(report.findings.count, ArchiveSafetyAnalyzer.findingLimit)
        XCTAssertTrue(report.isTruncated)
    }

    func testBlockedFindingsSortBeforeCautions() async {
        let entries = [entry("run.sh", id: 0), entry("../x", id: 1)]
        let report = await ArchiveSafetyAnalyzer.analyze(entries: entries, limits: ArchiveLimits())
        XCTAssertEqual(report.findings.map(\.kind), [.unsafePath, .executable])
        XCTAssertEqual(report.severityByEntryID[1], .blocked)
    }
}

final class ChecksumTests: XCTestCase {
    func testSHA256MatchesCryptoKit() async throws {
        let archive = try await openFixture("basic")
        for entry in archive.entries where entry.type == .file {
            let data = try await archive.contents(of: entry)
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let actual = try await archive.sha256(of: entry)
            XCTAssertEqual(actual, expected, entry.path)
        }
    }

    func testChecksumListFormat() async throws {
        let archive = try await openFixture("mixed")
        let (text, skipped) = try await archive.checksumList(for: archive.entries)
        XCTAssertTrue(skipped.isEmpty)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, archive.entries.filter { $0.type == .file }.count)
        for line in lines {
            let parts = line.components(separatedBy: "  ")
            XCTAssertEqual(parts.first?.count, 64)
            XCTAssertTrue(text.hasSuffix("\n"))
        }
    }

    func testChecksumListSkipsEncryptedAndCorruptEntries() async throws {
        let encrypted = try await openFixture("encrypted")
        let (_, skipped) = try await encrypted.checksumList(for: encrypted.entries)
        XCTAssertEqual(Set(skipped.map(\.path)), ["secret.txt", "aes.txt"])

        let corrupt = try await openFixture("bad_crc")
        let (text, skippedCorrupt) = try await corrupt.checksumList(for: corrupt.entries)
        XCTAssertFalse(skippedCorrupt.isEmpty, "a checksum is never produced for a corrupt entry")
        XCTAssertFalse(text.contains(skippedCorrupt[0].path))
    }
}

final class TreemapTests: XCTestCase {
    func testSquarifyFillsTheRectangleWithProportionalAreas() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let rects = Treemap.squarify(values, in: rect)
        XCTAssertEqual(rects.count, values.count)
        let total = values.reduce(0, +)
        for (value, r) in zip(values, rects) {
            XCTAssertEqual(Double(r.width * r.height), value / total * 240_000, accuracy: 1)
            XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(r))
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).width < 0.001 || a.intersection(b).height < 0.001)
            }
        }
    }

    func testZeroAndEmptyInput() {
        XCTAssertEqual(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [])
        XCTAssertEqual(Treemap.squarify([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [.zero, .zero])
    }

    func testLayoutNestsFoldersAndSkipsEmptyItems() async throws {
        let archive = try await openFixture("mixed")
        let tree = ArchiveTree(entries: archive.entries)
        let cells = Treemap.layout(tree.root, in: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(cells.isEmpty)
        XCTAssertTrue(cells.allSatisfy { $0.node.totalUncompressedSize > 0 })
        XCTAssertEqual(Set(cells.filter { $0.depth == 0 }.map(\.node.id)),
                       Set(tree.root.children.filter { $0.totalUncompressedSize > 0 }.map(\.id)))
    }

    func testCompressionRatio() async throws {
        let archive = try await openFixture("zeros")
        let tree = ArchiveTree(entries: archive.entries)
        let ratio = try XCTUnwrap(tree.root.compressionRatio)
        XCTAssertLessThan(ratio, 0.01)
        XCTAssertNil(ArchiveTree(entries: []).root.compressionRatio)
    }
}
