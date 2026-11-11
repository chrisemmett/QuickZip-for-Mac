import ArchiveKit
import Foundation

/// The `quickzip` command (HLD §20, Phase 7): list, extract, verify,
/// test-safety and checksum, for people and for scripts.
///
/// Every command goes through `ArchiveAutomation`, so it applies the same
/// safety rules and limits as the application and the Shortcuts actions.
/// With `--json` the result is printed as JSON (documented in docs/CLI.md).
///
/// This is a library, with `main.swift` in the `quickzip` target and in the
/// copy built into the application, so that it can be tested by calling
/// `run` and reading what it printed.
public enum QuickZipCLI {
    public static let version = "1.0"

    /// Exit codes. Scripts can rely on these.
    public enum Exit {
        public static let success: Int32 = 0
        /// The command failed: the archive could not be opened, an item was
        /// damaged or could not be extracted, a checksum could not be made.
        public static let failure: Int32 = 1
        /// The command line was wrong.
        public static let usage: Int32 = 64
        /// `test-safety` found items that would be refused.
        public static let unsafeItems: Int32 = 3
        /// `test-safety` found only items to be careful with.
        public static let cautionItems: Int32 = 4
    }

    public struct Console: Sendable {
        public var output: @Sendable (String) -> Void
        public var error: @Sendable (String) -> Void
        /// Whether progress should be shown (standard error is a terminal).
        public var showsProgress: Bool

        public init(output: @escaping @Sendable (String) -> Void, error: @escaping @Sendable (String) -> Void, showsProgress: Bool = false) {
            self.output = output
            self.error = error
            self.showsProgress = showsProgress
        }

        /// Standard output and standard error.
        public static var standard: Console {
            Console(
                // The throwing `write(contentsOf:)`: the older `write(_:)`
                // raises an Objective-C exception, which Swift cannot catch,
                // when the pipe has closed (`| head`) or the disk is full.
                output: { _ = try? FileHandle.standardOutput.write(contentsOf: Data(($0 + "\n").utf8)) },
                error: { _ = try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) },
                showsProgress: isatty(STDERR_FILENO) != 0
            )
        }
    }

    public static let usage = """
    usage: quickzip <command> [options] <archive>

    commands:
      list          list the items in an archive
      extract       extract items into a folder (-d)
      verify        decompress every item and check its size and checksum
      test-safety   report items extraction would refuse, and ones to be careful with
      checksum      print SHA-256 checksums in `shasum -a 256 -c` format

    options:
      -m, --match QUERY      only items matching QUERY: words match names, a word with /
                             matches paths, *.pdf or ext:pdf match extensions
      -d, --destination DIR  where extract writes (default: a folder named after the archive)
      --conflict POLICY      extract: keep-both (default), replace, skip or fail
      --json                 print the result as JSON
      --password-env NAME    read the password from environment variable NAME
                             (QUICKZIP_PASSWORD is read if set)
      --password-file PATH   read the password from the first line of a file
      --password-stdin       read the password from the first line of standard input
      -h, --help             show this help
      --version              show the version

    Passwords are never taken from the command line, where other users' `ps` would show them.

    exit status: 0 success, 1 failure, 64 usage error;
    test-safety: 0 nothing found, 3 unsafe items found, 4 only items to be careful with.
    """

    private struct Arguments {
        var command: String?
        var archive: String?
        var match: String?
        var destination: String?
        var conflict = ExtractionOptions.ConflictPolicy.keepBoth
        var json = false
        var passwordEnvironment: String?
        var passwordFile: String?
        var passwordStandardInput = false
        var help = false
        var showVersion = false
    }

    private struct UsageError: Error { var message: String }

    private static func parse(_ arguments: [String]) throws -> Arguments {
        var result = Arguments()
        var rest = arguments[...]
        func value(for option: String) throws -> String {
            guard let value = rest.popFirst() else { throw UsageError(message: "\(option) needs a value") }
            return value
        }
        var positional: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "-h", "--help": result.help = true
            case "--version": result.showVersion = true
            case "--json": result.json = true
            case "-m", "--match": result.match = try value(for: argument)
            case "-d", "--destination": result.destination = try value(for: argument)
            case "--conflict":
                switch try value(for: argument) {
                case "keep-both": result.conflict = .keepBoth
                case "replace": result.conflict = .replace
                case "skip": result.conflict = .skip
                case "fail": result.conflict = .fail
                case let other: throw UsageError(message: "unknown conflict policy “\(other)”")
                }
            case "--password-env": result.passwordEnvironment = try value(for: argument)
            case "--password-file": result.passwordFile = try value(for: argument)
            case "--password-stdin": result.passwordStandardInput = true
            case "--password", "-p":
                throw UsageError(message: "passwords are not accepted on the command line; use --password-env, --password-file or --password-stdin")
            case let option where option.hasPrefix("-") && option != "-":
                throw UsageError(message: "unknown option \(option)")
            default:
                positional.append(argument)
            }
        }
        result.command = positional.first
        if positional.count > 2 { throw UsageError(message: "too many arguments") }
        result.archive = positional.dropFirst().first
        return result
    }

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: @Sendable () -> String? = { readLine() },
        console: Console = .standard
    ) async -> Int32 {
        let parsed: Arguments
        do {
            parsed = try parse(arguments)
        } catch let error as UsageError {
            console.error("quickzip: \(error.message)\n\n\(usage)")
            return Exit.usage
        } catch {
            return Exit.usage
        }
        if parsed.showVersion {
            console.output("quickzip \(version)")
            return Exit.success
        }
        guard let command = parsed.command, !parsed.help else {
            (parsed.help ? console.output : console.error)(usage)
            return parsed.help ? Exit.success : Exit.usage
        }
        guard ["list", "extract", "verify", "test-safety", "checksum"].contains(command) else {
            console.error("quickzip: unknown command “\(command)”\n\n\(usage)")
            return Exit.usage
        }
        guard let archivePath = parsed.archive else {
            console.error("quickzip: \(command) needs an archive\n\n\(usage)")
            return Exit.usage
        }
        if command != "extract", parsed.destination != nil {
            console.error("quickzip: -d applies only to extract")
            return Exit.usage
        }

        let url = URL(fileURLWithPath: archivePath)
        var options = ArchiveAutomation.Options()
        do {
            options.password = try password(parsed, environment: environment, standardInput: standardInput)
        } catch let error as UsageError {
            console.error("quickzip: \(error.message)")
            return Exit.usage
        } catch {
            console.error("quickzip: the password could not be read: \(error.localizedDescription)")
            return Exit.failure
        }

        var progress: (@Sendable (Double) -> Void)?
        if console.showsProgress && !parsed.json {
            progress = { @Sendable fraction in
                if fraction < 1 { console.error("\rreading… \(Int(fraction * 100))%") }
            }
        }

        do {
            switch command {
            case "list":
                let result = try await ArchiveAutomation.list(url, matching: parsed.match, options: options, progress: progress)
                return printList(result, json: parsed.json, console: console)
            case "extract":
                let destination = parsed.destination.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? defaultDestination(for: url)
                let result = try await ArchiveAutomation.extract(
                    url, to: destination, matching: parsed.match, conflict: parsed.conflict, options: options, progress: progress
                )
                return printExtract(result, json: parsed.json, console: console)
            case "verify":
                let result = try await ArchiveAutomation.verify(url, options: options, progress: progress)
                return printVerify(result, json: parsed.json, console: console)
            case "test-safety":
                let result = try await ArchiveAutomation.safety(url, options: options, progress: progress)
                return printSafety(result, json: parsed.json, console: console)
            default:
                let result = try await ArchiveAutomation.checksums(url, matching: parsed.match, options: options, progress: progress)
                return printChecksums(result, json: parsed.json, console: console)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if parsed.json {
                let kind = (error as? ArchiveError)?.logKind ?? "error"
                console.output(encode(ErrorResult(error: .init(message: message, kind: kind))))
            } else {
                console.error("quickzip: \(message)")
            }
            return Exit.failure
        }
    }

    /// A folder named after the archive, beside it: `Photos.tar.gz` → `Photos`.
    public static func defaultDestination(for archive: URL) -> URL {
        var name = archive.lastPathComponent
        for suffix in [".tar.gz", ".tar.xz", ".tgz", ".txz"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            return archive.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        }
        return archive.deletingLastPathComponent()
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    // MARK: Passwords

    private static func password(
        _ arguments: Arguments, environment: [String: String], standardInput: () -> String?
    ) throws -> String? {
        if arguments.passwordStandardInput { return standardInput() }
        if let path = arguments.passwordFile {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
        }
        if let name = arguments.passwordEnvironment {
            guard let value = environment[name] else { throw UsageError(message: "the environment variable \(name) is not set") }
            return value
        }
        return environment["QUICKZIP_PASSWORD"]
    }

    // MARK: Output

    private struct ErrorResult: Codable {
        struct Detail: Codable { var message: String; var kind: String }
        var schema = ArchiveAutomation.schemaVersion
        var error: Detail
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func printList(_ result: ArchiveAutomation.ListResult, json: Bool, console: Console) -> Int32 {
        if json {
            console.output(encode(result))
            return Exit.success
        }
        for warning in result.warnings { console.error("warning: \(warning)") }
        for item in result.items {
            let kind = item.type == "directory" ? "d" : (item.type == "symlink" ? "l" : "-")
            let flag = item.encrypted ? "E" : " "
            let size = String(item.size).leftPadded(to: 12)
            let date = item.modified.map { String($0.prefix(16)).replacingOccurrences(of: "T", with: " ") } ?? "                "
            console.output("\(kind)\(flag) \(size) \(date) \(item.path)\(item.type == "directory" ? "/" : "")")
        }
        console.error("\(result.items.count) items")
        return Exit.success
    }

    private static func printExtract(_ result: ArchiveAutomation.ExtractResult, json: Bool, console: Console) -> Int32 {
        let failed = !result.failures.isEmpty
        if json {
            console.output(encode(result))
            return failed ? Exit.failure : Exit.success
        }
        for warning in result.warnings { console.error("warning: \(warning)") }
        for path in result.extracted { console.output(path) }
        for path in result.skipped { console.error("skipped: \(path)") }
        for failure in result.failures { console.error("error: \(failure.path): \(failure.error)") }
        console.error("extracted \(result.extracted.count) items to \(result.destination)"
            + (failed ? "; \(result.failures.count) failed" : ""))
        return failed ? Exit.failure : Exit.success
    }

    private static func printVerify(_ result: ArchiveAutomation.VerifyResult, json: Bool, console: Console) -> Int32 {
        if json {
            console.output(encode(result))
            return result.intact ? Exit.success : Exit.failure
        }
        for warning in result.warnings { console.error("warning: \(warning)") }
        for item in result.notChecked { console.output("SKIPPED  \(item.path) (\(item.error))") }
        for item in result.damaged { console.output("DAMAGED  \(item.path): \(item.error)") }
        console.output("\(result.verified) items verified, \(result.damaged.count) damaged, \(result.notChecked.count) not checked")
        return result.intact ? Exit.success : Exit.failure
    }

    private static func printSafety(_ result: ArchiveAutomation.SafetyResult, json: Bool, console: Console) -> Int32 {
        let code = !result.blocked.isEmpty ? Exit.unsafeItems : (!result.cautions.isEmpty ? Exit.cautionItems : Exit.success)
        if json {
            console.output(encode(result))
            return code
        }
        for finding in result.blocked { console.output("BLOCKED  \(finding.path): \(finding.kind)\(finding.detail.map { " (\($0))" } ?? "")") }
        for finding in result.cautions { console.output("CAUTION  \(finding.path): \(finding.kind)\(finding.detail.map { " (\($0))" } ?? "")") }
        if result.truncated { console.error("more findings than are listed") }
        if result.clean { console.output("nothing suspicious found") }
        return code
    }

    private static func printChecksums(_ result: ArchiveAutomation.ChecksumResult, json: Bool, console: Console) -> Int32 {
        let incomplete = !result.skipped.isEmpty
        if json {
            console.output(encode(result))
            return incomplete ? Exit.failure : Exit.success
        }
        if !result.items.isEmpty { console.output(String(result.listing.dropLast())) }
        for item in result.skipped { console.error("skipped: \(item.path): \(item.error)") }
        return incomplete ? Exit.failure : Exit.success
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
