import Foundation
import XCTest
@testable import ArchiveKit
#if canImport(Darwin)
import Darwin
#endif

/// `__MACOSX` AppleDouble metadata merged back on extraction (HLD §18.2).
final class AppleDoubleTests: XCTestCase {
    func testCompanionPath() {
        XCTAssertEqual(AppleDouble.companionPath(for: "Folder/file.txt"), "__MACOSX/Folder/._file.txt")
        XCTAssertEqual(AppleDouble.companionPath(for: "Folder"), "__MACOSX/._Folder")
        XCTAssertEqual(AppleDouble.companionPath(for: "a/b/c"), "__MACOSX/a/b/._c")
    }

    func testParsesFinderInfoAttributesAndResourceFork() async throws {
        let archive = try await openFixture("macos_metadata")
        let data = try await archive.contents(of: try archive.entry("__MACOSX/Folder/._file.txt"))
        let metadata = try AppleDouble(data)
        XCTAssertEqual(metadata.finderInfo?.prefix(8), Data("TEXTttxt".utf8))
        XCTAssertEqual(metadata.finderInfo?.count, 32)
        XCTAssertEqual(metadata.resourceFork, Data("resource fork bytes".utf8))
        // The archive's quarantine attribute is never taken.
        XCTAssertEqual(metadata.attributes.map(\.name), ["com.apple.metadata:_kMDItemUserTags", "org.example.note"])
        XCTAssertEqual(metadata.attributes.last?.value, Data("kept".utf8))
    }

    func testRejectsOtherData() {
        XCTAssertThrowsError(try AppleDouble(Data("not apple double".utf8)))
        XCTAssertThrowsError(try AppleDouble(Data()))
    }

    func testDamagedAttributesAreIgnored() async throws {
        let archive = try await openFixture("macos_metadata")
        var data = try await archive.contents(of: try archive.entry("__MACOSX/Folder/._file.txt"))
        // Point the first attribute's data far past the end of the file.
        let firstAttribute = 84 + 36
        data.replaceSubrange(firstAttribute..<firstAttribute + 4, with: [0x7F, 0xFF, 0xFF, 0xFF])
        let metadata = try AppleDouble(data)
        XCTAssertTrue(metadata.attributes.isEmpty)
        XCTAssertNotNil(metadata.finderInfo)
    }

    func testExtractionMergesMetadataAndSkipsCompanions() async throws {
        let archive = try await openFixture("macos_metadata")
        let destination = try makeTemporaryDirectory(self)
        let tree = ArchiveTree(entries: archive.entries)
        let folder = try XCTUnwrap(tree.node(atPath: "Folder"))
        let result = try await ArchiveExtractor(destination: destination)
            .extract(tree.entries(under: folder), from: archive)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("__MACOSX").path))
        let file = destination.appendingPathComponent("Folder/file.txt")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "contents")

        #if canImport(Darwin)
        XCTAssertEqual(extendedAttribute("org.example.note", of: file), Data("kept".utf8))
        XCTAssertEqual(extendedAttribute("com.apple.ResourceFork", of: file), Data("resource fork bytes".utf8))
        XCTAssertEqual(extendedAttribute("com.apple.FinderInfo", of: file)?.prefix(8), Data("TEXTttxt".utf8))
        XCTAssertNil(extendedAttribute("com.apple.quarantine", of: file))
        XCTAssertEqual(
            extendedAttribute("org.example.folder", of: destination.appendingPathComponent("Folder")),
            Data("folder note".utf8)
        )
        XCTAssertNil(extendedAttribute("org.example.note", of: destination.appendingPathComponent("Folder/plain.txt")))
        #endif
    }

    func testMergingCanBeTurnedOff() async throws {
        let archive = try await openFixture("macos_metadata")
        let destination = try makeTemporaryDirectory(self)
        let extractor = try ArchiveExtractor(destination: destination, options: ExtractionOptions(restoreMacOSMetadata: false))
        let url = try await extractor.extract(try archive.entry("Folder/file.txt"), from: archive)
        XCTAssertNotNil(url)
        #if canImport(Darwin)
        XCTAssertNil(extendedAttribute("org.example.note", of: try XCTUnwrap(url)))
        #endif
    }

    #if canImport(Darwin)
    private func extendedAttribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            return read == size ? data : nil
        }
    }
    #endif
}
