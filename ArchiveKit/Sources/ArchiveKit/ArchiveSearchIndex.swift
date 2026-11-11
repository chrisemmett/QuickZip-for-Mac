import Foundation

/// Filename search over an archive's folder hierarchy (HLD §12).
///
/// Built once from the central directory, so a search never touches the
/// archive file. Names and paths are folded (case, diacritics and width)
/// and stored as UTF-8 bytes up front, which keeps a search over 100,000
/// items to a plain byte scan (HLD §18.5: < 16 ms per keystroke).
///
/// A query is split on whitespace and every term must match:
/// - `*.pdf` or `ext:pdf` matches items with that extension;
/// - a term containing `/` matches anywhere in the item's path;
/// - anything else matches anywhere in the item's name.
public final class ArchiveSearchIndex: @unchecked Sendable {
    // Immutable after init.

    /// Every node below the root in depth-first order, so each folder's
    /// descendants are a contiguous range.
    private let nodes: [ArchiveNode]
    private let names: [[UInt8]]
    private let paths: [[UInt8]]
    private let extensions: [[UInt8]]
    /// Position of each folder in `nodes`, and the end of its descendants.
    private let subtrees: [ArchiveNode.ID: Range<Int>]

    public init(tree: ArchiveTree) {
        var nodes: [ArchiveNode] = []
        var subtrees: [ArchiveNode.ID: Range<Int>] = [:]
        // Iterative, because an archive can nest folders thousands deep.
        // A folder is pushed twice: to visit it, then to close its range
        // once everything below it has been visited.
        var stack: [(node: ArchiveNode, start: Int?)] = tree.root.children.reversed().map { (node: $0, start: Int?.none) }
        while let item = stack.popLast() {
            let node = item.node
            if let start = item.start {
                subtrees[node.id] = start ..< nodes.count
                continue
            }
            nodes.append(node)
            if node.isDirectory {
                stack.append((node: node, start: nodes.count))
                stack.append(contentsOf: node.children.reversed().map { (node: $0, start: Int?.none) })
            }
        }
        subtrees[tree.root.id] = 0 ..< nodes.count

        self.nodes = nodes
        self.subtrees = subtrees
        self.names = nodes.map { Self.fold($0.name) }
        self.paths = nodes.map { Self.fold($0.path) }
        self.extensions = nodes.map { node in
            guard !node.isDirectory, let dot = node.name.lastIndex(of: "."), dot != node.name.startIndex else { return [] }
            return Self.fold(String(node.name[node.name.index(after: dot)...]))
        }
    }

    /// Number of items indexed.
    public var count: Int { nodes.count }

    /// The items at or below `folder` (the whole archive when nil) matching
    /// `query`, in depth-first order. An empty query matches nothing.
    public func search(_ query: String, in folder: ArchiveNode? = nil) -> [ArchiveNode] {
        let terms = Self.parse(query)
        guard !terms.isEmpty else { return [] }
        let range = folder.flatMap { subtrees[$0.id] } ?? 0 ..< nodes.count
        var result: [ArchiveNode] = []
        for index in range where terms.allSatisfy({ matches($0, at: index) }) {
            result.append(nodes[index])
        }
        return result
    }

    enum Term: Equatable {
        case name([UInt8])
        case path([UInt8])
        case pathExtension([UInt8])
    }

    static func parse(_ query: String) -> [Term] {
        query.split(whereSeparator: \.isWhitespace).compactMap { word -> Term? in
            let text = String(word)
            for prefix in ["*.", "ext:"] where text.hasPrefix(prefix) {
                let ext = fold(String(text.dropFirst(prefix.count)))
                return ext.isEmpty ? nil : .pathExtension(ext)
            }
            let folded = fold(text)
            return text.contains("/") ? .path(folded) : .name(folded)
        }
    }

    private func matches(_ term: Term, at index: Int) -> Bool {
        switch term {
        case .name(let needle): return Self.contains(names[index], needle)
        case .path(let needle): return Self.contains(paths[index], needle)
        case .pathExtension(let ext): return extensions[index] == ext
        }
    }

    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let count = needle.count
        guard count > 0 else { return true }
        guard count <= haystack.count else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pattern in
                let first = pattern[0]
                var start = 0
                let last = hay.count - count
                while start <= last {
                    if hay[start] == first {
                        var offset = 1
                        while offset < count && hay[start + offset] == pattern[offset] { offset += 1 }
                        if offset == count { return true }
                    }
                    start += 1
                }
                return false
            }
        }
    }
}
