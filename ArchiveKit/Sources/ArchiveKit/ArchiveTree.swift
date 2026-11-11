import Foundation

/// A folder or item in the browsable hierarchy of an archive.
///
/// Archives need not contain explicit directory entries, so folders implied
/// by entry paths are synthesised (`entry == nil`).
public final class ArchiveNode: Identifiable, @unchecked Sendable {
    // Immutable once `ArchiveTree` has finished building.

    /// Unique within a tree: the entry's id, or a negative number for
    /// synthesised folders.
    public let id: Int
    public let name: String
    /// The node's path within the archive (`""` for the root).
    public let path: String
    public let entry: ArchiveEntry?
    public let isDirectory: Bool
    public private(set) var children: [ArchiveNode] = []
    /// Total uncompressed size of this node and everything below it.
    public private(set) var totalUncompressedSize: UInt64 = 0
    /// Total compressed size of this node and everything below it.
    public private(set) var totalCompressedSize: UInt64 = 0
    /// Number of files and links below this node (folders not counted).
    public private(set) var descendantFileCount: Int = 0

    init(id: Int, name: String, path: String, entry: ArchiveEntry?, isDirectory: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.entry = entry
        self.isDirectory = isDirectory
    }

    /// Compressed size as a fraction of uncompressed size: 0.25 means the
    /// item is stored in a quarter of its size. Nil when nothing is
    /// uncompressed (empty items), so there is no ratio to speak of.
    public var compressionRatio: Double? {
        totalUncompressedSize > 0 ? Double(totalCompressedSize) / Double(totalUncompressedSize) : nil
    }

    /// Child folders only, for the sidebar.
    public var directoryChildren: [ArchiveNode] {
        children.filter(\.isDirectory)
    }

    fileprivate var childDirectories: [String: ArchiveNode] = [:]

    fileprivate func add(_ child: ArchiveNode) {
        children.append(child)
        if child.isDirectory { childDirectories[child.name] = child }
    }

    fileprivate func finish() {
        childDirectories = [:]
        children.sort { lhs, rhs in
            let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        totalUncompressedSize = entry?.uncompressedSize ?? 0
        totalCompressedSize = entry?.compressedSize ?? 0
        descendantFileCount = 0
        for child in children {
            child.finish()
            totalUncompressedSize &+= child.totalUncompressedSize
            totalCompressedSize &+= child.totalCompressedSize
            descendantFileCount += child.isDirectory ? child.descendantFileCount : 1
        }
    }
}

/// The folder hierarchy of an archive, built from its flat entry list
/// (HLD §6, "Construct ArchiveEntry hierarchy").
public struct ArchiveTree: Sendable {
    public let root: ArchiveNode

    /// Folders deeper than this are not shown as separate levels: the rest
    /// of the path becomes one name. A ZIP name can hold about 32,000
    /// components and a tar name about 500,000. Building, walking and
    /// freeing a tree that deep recurses once per level, which overflows
    /// the stack, most quickly on the small stacks of concurrent tasks.
    /// Extraction is unaffected: it uses each entry's full path.
    public static let maximumDepth = 256

    /// - Parameter includeMacOSMetadata: whether to show `__MACOSX` entries,
    ///   which are hidden by default (HLD §18.2).
    public init(entries: [ArchiveEntry], archiveName: String = "", includeMacOSMetadata: Bool = false) {
        var nextSyntheticID = -1
        let root = ArchiveNode(id: Int.min, name: archiveName, path: "", entry: nil, isDirectory: true)

        func directory(for components: ArraySlice<String>) -> ArchiveNode {
            var node = root
            var path = ""
            for component in components {
                path = path.isEmpty ? component : path + "/" + component
                if let existing = node.childDirectories[component] {
                    node = existing
                    continue
                }
                let child = ArchiveNode(id: nextSyntheticID, name: component, path: path, entry: nil, isDirectory: true)
                nextSyntheticID -= 1
                node.add(child)
                node = child
            }
            return node
        }

        // Explicit directory entries first, shallowest first, so that each is
        // in place before anything inside it would synthesise it.
        let explicitDirectories = entries
            .filter { $0.type == .directory }
            .sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        let ordered = explicitDirectories + entries.filter { $0.type != .directory }
        for entry in ordered {
            if !includeMacOSMetadata && entry.isMacOSMetadata { continue }
            // Lenient split for display only; extraction uses PathSanitizer.
            var components = entry.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." }
            if components.count > Self.maximumDepth {
                let rest = components[(Self.maximumDepth - 1)...].joined(separator: "/")
                components = Array(components.prefix(Self.maximumDepth - 1)) + [rest]
            }
            guard let name = components.last else { continue }
            let parent = directory(for: components.dropLast())
            let path = components.joined(separator: "/")

            if entry.type == .directory {
                // A repeated directory entry adds nothing new.
                if parent.childDirectories[name] == nil {
                    parent.add(ArchiveNode(id: entry.id, name: name, path: path, entry: entry, isDirectory: true))
                }
            } else {
                parent.add(ArchiveNode(id: entry.id, name: name, path: path, entry: entry, isDirectory: false))
            }
        }

        root.finish()
        self.root = root
    }

    /// The node at `path`, or nil.
    public func node(atPath path: String) -> ArchiveNode? {
        var node = root
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.isDirectory && $0.name == component })
                ?? node.children.first(where: { $0.name == component })
            else { return nil }
            node = next
        }
        return node
    }

    /// Every real entry at or beneath `node`, in depth-first order: what
    /// "Extract" on a folder needs.
    public func entries(under node: ArchiveNode) -> [ArchiveEntry] {
        var result: [ArchiveEntry] = []
        func visit(_ node: ArchiveNode) {
            if let entry = node.entry { result.append(entry) }
            node.children.forEach(visit)
        }
        visit(node)
        return result
    }
}
