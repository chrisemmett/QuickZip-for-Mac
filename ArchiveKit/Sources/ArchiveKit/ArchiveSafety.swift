import Foundation

/// Something suspicious about one entry, found before anything is extracted
/// (HLD §20, Phase 3 "Pre-extraction safety report").
public struct SafetyFinding: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// The path would be written outside the destination.
        case unsafePath
        /// A link that points outside the destination.
        case unsafeSymlink
        /// The declared size or compression ratio looks like a ZIP bomb.
        case exceedsLimits
        /// The entry shares data with another, as overlapping ZIP bombs do.
        case overlappingData
        /// An application bundle (`.app`).
        case applicationBundle
        /// A file that opens as a program or installer when double-clicked.
        case executable
        /// A name such as `invoice.pdf.app`: a document name in front of a
        /// program's extension.
        case doubleExtension
        /// Right-to-left overrides and invisible characters in the name,
        /// which can make `fdp.exe` read as `exe.pdf`.
        case deceptiveCharacters
    }

    public enum Severity: Int, Comparable, Sendable {
        /// Extraction refuses the entry.
        case blocked
        /// Extraction proceeds; the user should know.
        case caution

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let entry: ArchiveEntry
    public let kind: Kind
    /// Specifics for the kind, never localized: the link's target, the
    /// bundle's path, the claimed extension, or the limit exceeded.
    public let detail: String?

    public var id: String { "\(entry.id)-\(kind.rawValue)" }

    public var severity: Severity {
        switch kind {
        case .unsafePath, .unsafeSymlink, .exceedsLimits, .overlappingData: return .blocked
        case .applicationBundle, .executable, .doubleExtension, .deceptiveCharacters: return .caution
        }
    }
}

/// Everything `ArchiveSafetyAnalyzer` found in an archive.
public struct ArchiveSafetyReport: Sendable {
    /// Blocked findings first, then in the order of `Kind.allCases`, then
    /// archive order.
    public let findings: [SafetyFinding]
    /// True if there were more findings than are kept.
    public let isTruncated: Bool

    public static let empty = ArchiveSafetyReport(findings: [], isTruncated: false)

    public var isEmpty: Bool { findings.isEmpty }
    public var blocked: [SafetyFinding] { findings.filter { $0.severity == .blocked } }
    public var cautions: [SafetyFinding] { findings.filter { $0.severity == .caution } }

    public func findings(for entryID: ArchiveEntry.ID) -> [SafetyFinding] {
        findings.filter { $0.entry.id == entryID }
    }

    /// The most serious finding for each entry, for marking rows.
    public var severityByEntryID: [ArchiveEntry.ID: SafetyFinding.Severity] {
        var result: [ArchiveEntry.ID: SafetyFinding.Severity] = [:]
        for finding in findings {
            result[finding.entry.id] = min(result[finding.entry.id] ?? .caution, finding.severity)
        }
        return result
    }
}

/// Surfaces the §13 checks as a report rather than an error at extraction
/// time. Reads only the directory, plus the few bytes of each symbolic link.
public enum ArchiveSafetyAnalyzer {
    /// Findings kept at most; a hostile archive could otherwise make the
    /// report as large as the archive.
    public static let findingLimit = 5_000
    /// Links read at most, for the same reason.
    static let symlinkLimit = 2_000

    /// Extensions of files that run or install when opened. Common
    /// scripting extensions that are also everyday source files (`js`, `py`,
    /// `pl`) are left out so the banner stays meaningful.
    static let executableExtensions: Set<String> = [
        "app", "command", "tool", "workflow", "action", "terminal", "scpt", "scptd", "applescript",
        "sh", "bash", "zsh", "csh", "pkg", "mpkg", "dmg", "exe", "msi", "bat", "cmd", "com", "scr",
        "ps1", "vbs", "vbe", "wsf", "hta", "lnk", "jar", "appex", "prefpane", "saver", "service",
    ]

    /// Extensions people expect to be inert documents or media.
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "txt",
        "csv", "jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "bmp", "svg", "mp3", "m4a", "wav",
        "mp4", "mov", "avi", "mkv", "zip", "html", "htm",
    ]

    public static func analyze(
        entries: [ArchiveEntry],
        limits: ArchiveLimits,
        overlappingEntryIDs: Set<Int> = [],
        symlinkTarget: (ArchiveEntry) async -> String? = { _ in nil }
    ) async -> ArchiveSafetyReport {
        var findings: [SafetyFinding] = []
        var seenBundles = Set<String>()
        var linksRead = 0
        var truncated = false

        func add(_ entry: ArchiveEntry, _ kind: SafetyFinding.Kind, _ detail: String? = nil) {
            if findings.count >= findingLimit {
                truncated = true
            } else {
                findings.append(SafetyFinding(entry: entry, kind: kind, detail: detail))
            }
        }

        for entry in entries {
            if Task.isCancelled { break }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var isUnsafe = false
            var safeComponents: [String] = []
            do {
                safeComponents = try PathSanitizer.safeComponents(of: entry.path)
            } catch {
                isUnsafe = true
                add(entry, .unsafePath)
            }

            if entry.type == .symlink, !isUnsafe, linksRead < symlinkLimit {
                linksRead += 1
                if entry.uncompressedSize > ArchiveExtractor.maximumSymlinkTargetLength {
                    add(entry, .unsafeSymlink, "")
                } else if let target = await symlinkTarget(entry),
                          !PathSanitizer.isSymlinkTargetContained(target, linkComponents: safeComponents) {
                    add(entry, .unsafeSymlink, String(target.prefix(300)))
                }
            }

            if entry.type == .file, let reason = limitViolation(entry, limits: limits) {
                add(entry, .exceedsLimits, reason)
            }
            if overlappingEntryIDs.contains(entry.id) {
                add(entry, .overlappingData)
            }
            if entry.isMacOSMetadata { continue }

            if hasDeceptiveCharacters(entry.path) {
                add(entry, .deceptiveCharacters)
            }

            // An application bundle is reported once, however many items it holds.
            if let bundleEnd = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                let bundle = components[...bundleEnd].joined(separator: "/")
                if seenBundles.insert(bundle).inserted {
                    add(entry, .applicationBundle, bundle)
                }
                if let claimed = claimedExtension(of: components[bundleEnd]) {
                    if seenBundles.insert(bundle + "#double").inserted {
                        add(entry, .doubleExtension, claimed)
                    }
                }
                continue
            }

            guard entry.type == .file, let name = components.last else { continue }
            if let claimed = claimedExtension(of: name) {
                add(entry, .doubleExtension, claimed)
            } else if executableExtensions.contains(entry.pathExtension) {
                add(entry, .executable, entry.pathExtension)
            }
        }

        let order = Dictionary(uniqueKeysWithValues: SafetyFinding.Kind.allCases.enumerated().map { ($1, $0) })
        findings.sort {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            return $0.entry.id < $1.entry.id
        }
        return ArchiveSafetyReport(findings: findings, isTruncated: truncated)
    }

    /// The document extension a name pretends to have (`pdf` in
    /// `invoice.pdf.exe`), if it ends in a program's extension.
    static func claimedExtension(of name: String) -> String? {
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let last = parts.last, executableExtensions.contains(String(last)) else { return nil }
        let claimed = String(parts[parts.count - 2])
        return documentExtensions.contains(claimed) ? claimed : nil
    }

    static func hasDeceptiveCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: return true
            default: return false
            }
        }
    }

    private static func limitViolation(_ entry: ArchiveEntry, limits: ArchiveLimits) -> String? {
        do {
            try limits.check(entry)
            return nil
        } catch let error as ArchiveError {
            if case .exceedsLimits(_, let reason) = error { return reason }
            return nil
        } catch {
            return nil
        }
    }
}

extension ArchiveProvider {
    /// Analyses the archive for anything suspicious (see `ArchiveSafetyAnalyzer`).
    public func safetyReport() async -> ArchiveSafetyReport {
        let entries = await self.entries
        let report = await ArchiveSafetyAnalyzer.analyze(
            entries: entries,
            limits: limits,
            overlappingEntryIDs: overlappingEntryIDs,
            symlinkTarget: { entry in
                guard let data = try? await self.contents(of: entry) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        )
        ArchiveLog.parsing.info("Safety report: \(report.blocked.count) blocked, \(report.cautions.count) cautions")
        return report
    }
}
