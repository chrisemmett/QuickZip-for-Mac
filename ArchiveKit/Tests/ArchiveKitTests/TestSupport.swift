import Foundation
import XCTest
@testable import ArchiveKit

/// URL of a checked-in fixture (see Scripts/make_fixtures.py).
func fixtureURL(_ name: String, extension ext: String = "zip") -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
        fatalError("Missing fixture \(name).zip")
    }
    return url
}

func openFixture(_ name: String, options: ZIPArchiveOptions = ZIPArchiveOptions()) async throws -> ZIPArchive {
    try await ZIPArchive.open(fixtureURL(name), options: options)
}

extension ZIPArchive {
    nonisolated func entry(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> ArchiveEntry {
        try XCTUnwrap(entries.first { $0.path == path }, "no entry \(path)", file: file, line: line)
    }

    func string(_ path: String) async throws -> String {
        String(decoding: try await contents(of: try entry(path)), as: UTF8.self)
    }
}

/// Asserts that `body` throws exactly `expected`.
func assertThrows<T>(
    _ expected: ArchiveError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected) but nothing was thrown", file: file, line: line)
    } catch let error as ArchiveError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected) but got \(error)", file: file, line: line)
    }
}

/// A fresh temporary directory, removed when the test finishes.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }
    return url.resolvingSymlinksInPath()
}

func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? Int)
}

extension TarArchive {
    nonisolated func entry(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> ArchiveEntry {
        try XCTUnwrap(entries.first { $0.path == path }, "no entry \(path)", file: file, line: line)
    }

    func string(_ path: String) async throws -> String {
        String(decoding: try await contents(of: try entry(path)), as: UTF8.self)
    }
}

extension AppleArchiveProvider {
    nonisolated func entry(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> ArchiveEntry {
        try XCTUnwrap(entries.first { $0.path == path }, "no entry \(path)", file: file, line: line)
    }

    func string(_ path: String) async throws -> String {
        String(decoding: try await contents(of: try entry(path)), as: UTF8.self)
    }
}
