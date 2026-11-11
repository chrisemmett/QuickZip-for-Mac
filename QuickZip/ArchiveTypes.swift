import Foundation
import UniformTypeIdentifiers

/// What the application opens, by file extension (HLD §18.4, Phase 6).
enum ArchiveTypes {
    /// Plain archives, which can be browsed, extracted from and (ZIP only) edited.
    static let archiveExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "txz", "xz", "aar"]

    /// ZIP files that are really documents or packages. They open read-only:
    /// they have ordering and content requirements (a `mimetype` entry first
    /// in an EPUB, `[Content_Types].xml` in Office files) that adding or
    /// deleting items would break.
    static let documentExtensions: Set<String> = [
        "ipa", "jar", "epub", "docx", "xlsx", "pptx", "odt", "ods", "odp", "apk", "war",
    ]

    static let openableExtensions = archiveExtensions.union(documentExtensions)

    static func isDocument(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    static func isOpenable(_ url: URL) -> Bool {
        openableExtensions.contains(url.pathExtension.lowercased())
    }

    /// For the Open panel.
    static var openPanelTypes: [UTType] {
        openableExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }
}
