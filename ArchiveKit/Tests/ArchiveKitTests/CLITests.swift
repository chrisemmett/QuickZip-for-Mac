import QuickZipCLI
import XCTest
@testable import ArchiveKit

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    func addOut(_ line: String) { lock.lock(); out.append(line); lock.unlock() }
    func addErr(_ line: String) { lock.lock(); err.append(line); lock.unlock() }
    var stdout: String { lock.lock(); defer { lock.unlock() }; return out.joined(separator: "\n") }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return err.joined(separator: "\n") }
}

final class CLITests: XCTestCase {
    private func run(
        _ arguments: [String], environment: [String: String] = [:], input: String? = nil
    ) async -> (code: Int32, stdout: String, stderr: String) {
        let captured = Captured()
        let console = QuickZipCLI.Console(output: { captured.addOut($0) }, error: { captured.addErr($0) })
        let code = await QuickZipCLI.run(arguments, environment: environment, standardInput: { input }, console: console)
        return (code, captured.stdout, captured.stderr)
    }

    private func path(_ name: String, _ ext: String = "zip") -> String { fixtureURL(name, extension: ext).path }

    func testHelpVersionAndUsageErrors() async {
        let help = await run(["--help"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.stdout.contains("usage: quickzip"))
        let version = await run(["--version"])
        XCTAssertEqual(version.stdout, "quickzip \(QuickZipCLI.version)")

        for arguments in [[], ["nonsense", "x.zip"], ["list"], ["list", "a", "b"], ["list", "--bogus", "x"], ["extract", "--conflict", "maybe", "x"], ["list", "-d", "x", "y"]] {
            let result = await run(arguments)
            XCTAssertEqual(result.code, 64, "\(arguments)")
            XCTAssertTrue(result.stderr.contains("usage") || result.stderr.contains("quickzip:"), "\(arguments)")
        }
    }

    func testPasswordsAreNeverTakenFromTheCommandLine() async {
        for flag in ["-p", "--password"] {
            let result = await run(["list", flag, "secret", path("basic")])
            XCTAssertEqual(result.code, 64)
            XCTAssertTrue(result.stderr.contains("not accepted on the command line"))
        }
    }

    func testListHumanAndJSON() async throws {
        let human = await run(["list", path("basic")])
        XCTAssertEqual(human.code, 0)
        XCTAssertTrue(human.stdout.contains("Holiday/notes.txt"))
        XCTAssertTrue(human.stdout.contains("Holiday/Photos/"), "folders end in a slash")
        XCTAssertTrue(human.stderr.contains("items"))

        let json = await run(["list", "--json", "-m", "notes.txt", path("basic")])
        XCTAssertEqual(json.code, 0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["path"] as? String }, ["Holiday/notes.txt"])
        XCTAssertTrue(json.stdout.contains("Holiday/notes.txt"), "slashes are not escaped")
    }

    func testExtractToADestination() async throws {
        let folder = try makeTemporaryDirectory(self).appendingPathComponent("out")
        let result = await run(["extract", "-d", folder.path, "-m", "notes.txt", path("basic")])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Holiday/notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Holiday/notes.txt").path))
    }

    func testExtractWithoutADestinationUsesAFolderBesideTheArchive() async throws {
        let directory = try makeTemporaryDirectory(self)
        let copy = directory.appendingPathComponent("photos.tar.gz")
        try FileManager.default.copyItem(at: fixtureURL("pax", extension: "tar.gz"), to: copy)
        let result = await run(["extract", copy.path])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("photos/hello.txt").path))
    }

    func testExtractFailureExitsNonZeroButWritesTheRest() async throws {
        let folder = try makeTemporaryDirectory(self).appendingPathComponent("out")
        let result = await run(["extract", "-d", folder.path, path("traversal")])
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.stderr.contains("evil"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("good.txt").path))
    }

    func testVerifyExitCodes() async {
        let r0 = await run(["verify", path("basic")])
        XCTAssertEqual(r0.code, 0)
        let bad = await run(["verify", path("bad_crc")])
        XCTAssertEqual(bad.code, 1)
        XCTAssertTrue(bad.stdout.contains("DAMAGED"))
        let json = await run(["verify", "--json", path("bad_crc")])
        XCTAssertEqual(json.code, 1)
        XCTAssertTrue(json.stdout.contains("\"intact\" : false"))
    }

    func testTestSafetyExitCodes() async {
        let r0 = await run(["test-safety", path("mixed")])
        XCTAssertEqual(r0.code, 0)
        let evil = await run(["test-safety", path("traversal")])
        XCTAssertEqual(evil.code, 3)
        XCTAssertTrue(evil.stdout.contains("BLOCKED"))
        let scripts = await run(["test-safety", path("pax", "tar")])
        XCTAssertEqual(scripts.code, 4)
        XCTAssertTrue(scripts.stdout.contains("CAUTION  bin/run.sh"))
    }

    func testChecksumOutputIsAcceptedByShasum() async throws {
        let listing = await run(["checksum", path("pax", "tar")])
        XCTAssertEqual(listing.code, 0, listing.stderr)
        let folder = try makeTemporaryDirectory(self)
        let extracted = await run(["extract", "-d", folder.path, path("pax", "tar")])
        XCTAssertEqual(extracted.code, 0, extracted.stderr)
        try (listing.stdout + "\n").write(to: folder.appendingPathComponent("sums.txt"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", "-c", "sums.txt"]
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testPasswordSources() async throws {
        let locked = await run(["checksum", path("aes256")])
        XCTAssertEqual(locked.code, 1)
        XCTAssertTrue(locked.stderr.contains("skipped"))

        let viaDefault = await run(["checksum", path("aes256")], environment: ["QUICKZIP_PASSWORD": "secret"])
        XCTAssertEqual(viaDefault.code, 0)
        let named = await run(["checksum", "--password-env", "PW", path("aes256")], environment: ["PW": "secret"])
        XCTAssertEqual(named.code, 0)
        let missing = await run(["checksum", "--password-env", "NOPE", path("aes256")])
        XCTAssertEqual(missing.code, 64)
        let stdin = await run(["checksum", "--password-stdin", path("aes256")], input: "secret")
        XCTAssertEqual(stdin.code, 0)
        let file = try makeTemporaryDirectory(self).appendingPathComponent("pw")
        try "secret\nsecond line\n".write(to: file, atomically: true, encoding: .utf8)
        let viaFile = await run(["checksum", "--password-file", file.path, path("aes256")])
        XCTAssertEqual(viaFile.code, 0)
        let wrong = await run(["checksum", path("aes256")], environment: ["QUICKZIP_PASSWORD": "wrong"])
        XCTAssertEqual(wrong.code, 1)
    }

    func testErrorsAsJSONAndUnsupportedFormats() async throws {
        let human = await run(["list", path("fake", "7z")])
        XCTAssertEqual(human.code, 1)
        XCTAssertTrue(human.stderr.contains("7z archive"))
        let json = await run(["list", "--json", path("fake", "7z")])
        XCTAssertEqual(json.code, 1)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: String])
        XCTAssertEqual(error["kind"], "unsupportedFormat")
        let missing = await run(["list", "/no/such/archive.zip"])
        XCTAssertEqual(missing.code, 1)
    }

    func testDefaultDestinationNames() {
        XCTAssertEqual(QuickZipCLI.defaultDestination(for: URL(fileURLWithPath: "/tmp/a/Photos.zip")).path, "/tmp/a/Photos")
        XCTAssertEqual(QuickZipCLI.defaultDestination(for: URL(fileURLWithPath: "/tmp/a/Photos.tar.gz")).path, "/tmp/a/Photos")
        XCTAssertEqual(QuickZipCLI.defaultDestination(for: URL(fileURLWithPath: "/tmp/a/Photos.TGZ")).path, "/tmp/a/Photos")
        XCTAssertEqual(QuickZipCLI.defaultDestination(for: URL(fileURLWithPath: "/tmp/a/Photos.tar")).path, "/tmp/a/Photos")
    }
}
