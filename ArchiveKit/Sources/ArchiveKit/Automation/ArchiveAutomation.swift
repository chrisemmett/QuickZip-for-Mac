import Foundation

/// The operations the command-line tool and the Shortcuts actions offer
/// (HLD §20, Phase 7), in one place so that both go through the same
/// `ArchiveProvider`, extractor and limits as the application, and so a
/// result means the same thing wherever it is shown.
///
/// Results are `Codable` with stable field names: they are what
/// `quickzip --json` prints.
public enum ArchiveAutomation {
    /// Version of the JSON the results encode to. Changes only when a field
    /// is removed or changes meaning; adding fields does not change it.
    public static let schemaVersion = 1

    public struct Options: Sendable {
        public var password: String?
        public var limits: ArchiveLimits
        public var filenameEncoding: FilenameEncoding

        public init(password: String? = nil, limits: ArchiveLimits = ArchiveLimits(), filenameEncoding: FilenameEncoding = .automatic) {
            self.password = password
            self.limits = limits
            self.filenameEncoding = filenameEncoding
        }
    }

    // MARK: Results

    public struct Item: Codable, Sendable, Hashable {
        public var path: String
        public var type: String
        public var size: UInt64
        public var compressedSize: UInt64
        public var modified: String?
        public var method: String
        public var encrypted: Bool
        public var mode: String?
    }

    public struct ListResult: Codable, Sendable {
        public var schema = ArchiveAutomation.schemaVersion
        public var archive: String
        public var items: [Item]
        public var warnings: [String]
    }

    public struct Failure: Codable, Sendable, Hashable {
        public var path: String
        public var error: String
        public var kind: String
    }

    public struct ExtractResult: Codable, Sendable {
        public var schema = ArchiveAutomation.schemaVersion
        public var archive: String
        public var destination: String
        /// Paths written, relative to `destination`.
        public var extracted: [String]
        public var skipped: [String]
        public var failures: [Failure]
        public var warnings: [String]
    }

    public struct VerifyResult: Codable, Sendable {
        public var schema = ArchiveAutomation.schemaVersion
        public var archive: String
        public var verified: Int
        public var damaged: [Failure]
        /// Items that could not be checked (encrypted without a password, or
        /// compressed in a way that is not supported), with the reason.
        public var notChecked: [Failure]
        public var intact: Bool
        public var warnings: [String]
    }

    public struct SafetyFindingResult: Codable, Sendable, Hashable {
        public var path: String
        public var kind: String
        public var severity: String
        public var detail: String?
    }

    public struct SafetyResult: Codable, Sendable {
        public var schema = ArchiveAutomation.schemaVersion
        public var archive: String
        public var blocked: [SafetyFindingResult]
        public var cautions: [SafetyFindingResult]
        public var truncated: Bool
        public var clean: Bool
    }

    public struct ChecksumItem: Codable, Sendable, Hashable {
        public var path: String
        public var sha256: String
    }

    public struct ChecksumResult: Codable, Sendable {
        public var schema = ArchiveAutomation.schemaVersion
        public var archive: String
        public var algorithm = "sha256"
        public var items: [ChecksumItem]
        public var skipped: [Failure]

        /// `shasum -a 256 -c` format.
        public var listing: String {
            items.map { "\($0.sha256)  \($0.path.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))" }
                .joined(separator: "\n") + (items.isEmpty ? "" : "\n")
        }
    }

    // MARK: Opening

    /// Opens any supported archive and gives it the password, if there is
    /// one. Slow formats report progress and honour cancellation.
    public static func open(
        _ url: URL,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> any ArchiveProvider {
        let archive = try await ArchiveOpener.open(
            url,
            options: ArchiveOpenOptions(filenameEncoding: options.filenameEncoding, limits: options.limits),
            progress: progress
        )
        if let password = options.password { await archive.setPassword(password) }
        return archive
    }

    /// The entries whose paths match `query` (the search syntax of the
    /// application: words match names, a word with `/` matches paths,
    /// `*.pdf` or `ext:pdf` match extensions), with everything inside a
    /// matching folder. All entries when `query` is nil or blank.
    public static func select(
        _ entries: [ArchiveEntry], matching query: String?
    ) -> [ArchiveEntry] {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
        let tree = ArchiveTree(entries: entries, archiveName: "", includeMacOSMetadata: true)
        let index = ArchiveSearchIndex(tree: tree)
        var chosen = Set<Int>()
        for node in index.search(query) {
            for entry in tree.entries(under: node) { chosen.insert(entry.id) }
        }
        return entries.filter { chosen.contains($0.id) }
    }

    // MARK: Operations

    public static func list(
        _ url: URL, matching query: String? = nil, options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ListResult {
        let archive = try await open(url, options: options, progress: progress)
        let entries = select(await archive.entries, matching: query)
        let formatter = ISO8601DateFormatter()
        let items = entries.map { entry in
            Item(
                path: entry.path,
                type: entry.type.rawValue,
                size: entry.uncompressedSize,
                compressedSize: entry.compressedSize,
                modified: entry.modificationDate.map { formatter.string(from: $0) },
                method: entry.compressionMethod.description,
                encrypted: entry.isEncrypted,
                mode: entry.posixPermissions.map { String($0, radix: 8) }
            )
        }
        return ListResult(archive: url.path, items: items, warnings: await archive.warnings)
    }

    public static func extract(
        _ url: URL, to destination: URL, matching query: String? = nil,
        conflict: ExtractionOptions.ConflictPolicy = .keepBoth,
        options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExtractResult {
        let archive = try await open(url, options: options, progress: progress)
        let entries = select(await archive.entries, matching: query)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let extractor = try ArchiveExtractor(destination: destination, options: ExtractionOptions(conflictPolicy: conflict))
        let result = try await extractor.extract(entries, from: archive)
        let root = extractor.destination.path + "/"
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        }
        return ExtractResult(
            archive: url.path,
            destination: extractor.destination.path,
            extracted: result.extracted.map(relative),
            skipped: result.skipped.map(\.path),
            failures: result.failures.map { Failure(path: $0.entry.path, error: $0.error.errorDescription ?? "\($0.error)", kind: $0.error.logKind) },
            warnings: await archive.warnings
        )
    }

    public static func verify(
        _ url: URL, options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VerifyResult {
        let archive = try await open(url, options: options, progress: progress)
        let report = try await archive.verify()
        return VerifyResult(
            archive: url.path,
            verified: report.verifiedCount,
            damaged: report.failures.map { Failure(path: $0.entry.path, error: $0.error.errorDescription ?? "\($0.error)", kind: $0.error.logKind) },
            notChecked: report.unverifiable.map { entry in
                Failure(
                    path: entry.path,
                    error: entry.needsPassword ? "needs a password" : (entry.isEncrypted ? "unsupported encryption" : "unsupported compression: \(entry.compressionMethod.description)"),
                    kind: entry.needsPassword ? "passwordRequired" : "unsupported"
                )
            },
            intact: report.isIntact,
            warnings: await archive.warnings
        )
    }

    public static func safety(
        _ url: URL, options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SafetyResult {
        let archive = try await open(url, options: options, progress: progress)
        let report = await archive.safetyReport()
        func convert(_ finding: SafetyFinding) -> SafetyFindingResult {
            SafetyFindingResult(
                path: finding.entry.path, kind: finding.kind.rawValue,
                severity: finding.severity == .blocked ? "blocked" : "caution", detail: finding.detail
            )
        }
        return SafetyResult(
            archive: url.path, blocked: report.blocked.map(convert), cautions: report.cautions.map(convert),
            truncated: report.isTruncated, clean: report.isEmpty
        )
    }

    public static func checksums(
        _ url: URL, matching query: String? = nil, options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ChecksumResult {
        let archive = try await open(url, options: options, progress: progress)
        let entries = select(await archive.entries, matching: query).filter { $0.type == .file }
        var items: [ChecksumItem] = []
        var skipped: [Failure] = []
        for entry in entries {
            try Task.checkCancellation()
            do {
                items.append(ChecksumItem(path: entry.path, sha256: try await archive.sha256(of: entry)))
            } catch let error as ArchiveError {
                skipped.append(Failure(path: entry.path, error: error.errorDescription ?? "\(error)", kind: error.logKind))
            }
        }
        return ChecksumResult(archive: url.path, items: items, skipped: skipped)
    }
}
