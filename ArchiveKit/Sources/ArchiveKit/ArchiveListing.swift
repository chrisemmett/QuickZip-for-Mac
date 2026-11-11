import Foundation

/// A self-contained HTML listing of an archive, for the Quick Look
/// extension (HLD §20, Phase 4). Pure: it takes entries and returns text,
/// so it runs wherever ArchiveKit does and is easy to test.
///
/// The page has no script and loads nothing. Names are escaped and shown
/// in their own bidirectional-isolation scope, so a name containing a
/// right-to-left override cannot rearrange the text around it.
public enum ArchiveListing {
    /// Rows kept at most; the rest are counted.
    public static let rowLimit = 3_000

    public struct Labels: Sendable {
        public var items: @Sendable (Int) -> String
        public var uncompressed: @Sendable (String) -> String
        public var stored: @Sendable (String, String) -> String
        public var more: @Sendable (Int) -> String
        public var warning: @Sendable (Int) -> String
        public var empty: String
        public var name: String
        public var size: String
        public var modified: String

        public init(
            items: @escaping @Sendable (Int) -> String,
            uncompressed: @escaping @Sendable (String) -> String,
            stored: @escaping @Sendable (String, String) -> String,
            more: @escaping @Sendable (Int) -> String,
            warning: @escaping @Sendable (Int) -> String,
            empty: String, name: String, size: String, modified: String
        ) {
            self.items = items; self.uncompressed = uncompressed; self.stored = stored
            self.more = more; self.warning = warning; self.empty = empty
            self.name = name; self.size = size; self.modified = modified
        }

        /// English, for tests and for callers with no catalog.
        public static let english = Labels(
            items: { $0 == 1 ? "1 item" : "\($0) items" },
            uncompressed: { "\($0) uncompressed" },
            stored: { "\($0) in the archive (\($1) saved)" },
            more: { "…and \($0) more items" },
            warning: { $0 == 1 ? "1 item to be careful with" : "\($0) items to be careful with" },
            empty: "This archive is empty.",
            name: "Name", size: "Size", modified: "Modified"
        )
    }

    public static func html(
        archiveName: String,
        entries: [ArchiveEntry],
        flaggedEntryIDs: Set<Int> = [],
        labels: Labels = .english,
        locale: Locale = .current
    ) -> String {
        let tree = ArchiveTree(entries: entries, archiveName: archiveName)
        let byteFormat = ByteCountFormatStyle(style: .file, locale: locale)
        let size = { (bytes: UInt64) in Int64(clamping: bytes).formatted(byteFormat) }
        let dates = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)

        var rows = ""
        var shown = 0
        var total = 0
        func visit(_ node: ArchiveNode, depth: Int) {
            for child in node.children {
                total += 1
                if shown < rowLimit {
                    shown += 1
                    let flagged = child.entry.map { flaggedEntryIDs.contains($0.id) } ?? false
                    rows += row(child, depth: depth, flagged: flagged, size: size, dates: dates)
                }
                if child.isDirectory { visit(child, depth: depth + 1) }
            }
        }
        visit(tree.root, depth: 0)

        let files = tree.root.descendantFileCount
        var summary = [labels.items(files), labels.uncompressed(size(tree.root.totalUncompressedSize))]
        if let ratio = tree.root.compressionRatio, ratio < 0.98 {
            let saved = max(1 - ratio, 0).formatted(.percent.precision(.fractionLength(0)).locale(locale))
            summary = [labels.items(files), labels.stored(size(tree.root.totalCompressedSize), saved)]
        }

        var body = ""
        if !flaggedEntryIDs.isEmpty {
            body += "<p class=\"warn\">⚠︎ \(escape(labels.warning(flaggedEntryIDs.count)))</p>"
        }
        if total == 0 {
            body += "<p class=\"empty\">\(escape(labels.empty))</p>"
        } else {
            body += "<table><thead><tr><th>\(escape(labels.name))</th><th class=\"n\">\(escape(labels.size))</th><th>\(escape(labels.modified))</th></tr></thead><tbody>\(rows)</tbody></table>"
            if total > shown {
                body += "<p class=\"more\">\(escape(labels.more(total - shown)))</p>"
            }
        }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; margin: 0; padding: 14px 18px; }
        h1 { font-size: 17px; margin: 0 0 2px; word-break: break-all; }
        .sum { color: GrayText; margin: 0 0 12px; }
        .warn { margin: 0 0 10px; padding: 6px 10px; border-radius: 6px; background: rgba(255, 159, 10, 0.18); }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; font-weight: 600; color: GrayText; border-bottom: 1px solid GrayText; padding: 3px 6px; position: sticky; top: 0; background: Canvas; }
        td { padding: 2px 6px; white-space: nowrap; }
        .n { text-align: right; font-variant-numeric: tabular-nums; }
        td.name { max-width: 0; width: 60%; overflow: hidden; text-overflow: ellipsis; }
        td:not(.name) { color: GrayText; }
        .dir td.name { font-weight: 600; }
        bdi { unicode-bidi: isolate; }
        .more, .empty { color: GrayText; margin-top: 10px; }
        </style></head><body>
        <h1><bdi>\(escape(archiveName))</bdi></h1>
        <p class="sum">\(escape(summary.joined(separator: " · ")))</p>
        \(body)
        </body></html>
        """
    }

    private static func row(
        _ node: ArchiveNode, depth: Int, flagged: Bool,
        size: (UInt64) -> String, dates: Date.FormatStyle
    ) -> String {
        let indent = min(depth, 12) * 16
        let date = node.entry?.modificationDate.map { $0.formatted(dates) } ?? ""
        let mark = flagged ? "⚠︎ " : ""
        return "<tr class=\"\(node.isDirectory ? "dir" : "file")\"><td class=\"name\" style=\"padding-left:\(indent + 6)px\">\(mark)<bdi>\(escape(node.name))</bdi></td>"
            + "<td class=\"n\">\(escape(size(node.totalUncompressedSize)))</td><td>\(escape(date))</td></tr>\n"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
