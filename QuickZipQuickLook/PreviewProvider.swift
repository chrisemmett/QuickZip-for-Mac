import ArchiveKit
import Quartz
import UniformTypeIdentifiers
import os

/// Space on a ZIP in Finder shows its file listing (HLD §20, Phase 4).
///
/// Runs in its own sandboxed process and depends only on ArchiveKit, with
/// the same limits as the application (HLD §13): opening reads the
/// directory and nothing is decompressed.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let log = Logger(subsystem: ArchiveLog.subsystem, category: "preview")

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let archive: ZIPArchive
        do {
            archive = try await ZIPArchive.open(url)
        } catch {
            Self.log.error("Quick Look could not open the archive")
            throw error
        }
        let entries = archive.entries
        let report = await ArchiveSafetyAnalyzer.analyze(
            entries: entries,
            limits: archive.limits,
            overlappingEntryIDs: archive.overlappingEntryIDs
        )
        let flagged = Set(report.findings.map(\.entry.id))
        let html = ArchiveListing.html(
            archiveName: url.lastPathComponent,
            entries: entries,
            flaggedEntryIDs: flagged,
            labels: .localized
        )
        Self.log.info("Quick Look listed \(entries.count) items")

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 680, height: 820)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
        reply.title = url.lastPathComponent
        return reply
    }
}

extension ArchiveListing.Labels {
    /// Wording from this extension's String Catalog.
    static var localized: ArchiveListing.Labels {
        ArchiveListing.Labels(
            items: { String(localized: "\($0) items") },
            uncompressed: { String(localized: "\($0) uncompressed") },
            stored: { String(localized: "\($0) in the archive (\($1) saved)") },
            more: { String(localized: "…and \($0) more items") },
            warning: { String(localized: "\($0) items to be careful with") },
            empty: String(localized: "This archive is empty."),
            name: String(localized: "Name"),
            size: String(localized: "Size"),
            modified: String(localized: "Modified")
        )
    }
}
