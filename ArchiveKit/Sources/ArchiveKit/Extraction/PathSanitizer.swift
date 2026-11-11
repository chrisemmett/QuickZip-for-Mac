import Foundation

/// Turns untrusted archive paths into safe relative path components
/// (HLD §13, Path Traversal).
public enum PathSanitizer {
    /// Returns the components of `path`, or throws `ArchiveError.unsafePath`
    /// if writing it beneath a destination directory could escape that
    /// directory.
    ///
    /// Rejected: absolute paths, Windows drive or UNC prefixes, `..`
    /// components, NUL bytes and paths that are empty after normalisation.
    /// Empty and `.` components are dropped.
    public static func safeComponents(of path: String) throws -> [String] {
        let normalised = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalised.contains("\0") else { throw ArchiveError.unsafePath(path) }
        guard !normalised.hasPrefix("/") else { throw ArchiveError.unsafePath(path) }
        if normalised.count >= 2, normalised.dropFirst().first == ":", normalised.first?.isLetter == true {
            throw ArchiveError.unsafePath(path)
        }

        var components: [String] = []
        for component in normalised.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": throw ArchiveError.unsafePath(path)
            default: components.append(String(component))
            }
        }
        guard !components.isEmpty else { throw ArchiveError.unsafePath(path) }
        return components
    }

    /// Whether a symlink at `linkComponents` pointing to `target` stays
    /// inside the extraction root once resolved lexically.
    public static func isSymlinkTargetContained(_ target: String, linkComponents: [String]) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var resolved = Array(linkComponents.dropLast())
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !resolved.isEmpty else { return false }
                resolved.removeLast()
            default:
                resolved.append(String(component))
            }
        }
        return true
    }
}
