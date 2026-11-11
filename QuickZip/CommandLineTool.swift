import AppKit
import Foundation

/// The `quickzip` command inside the application, and putting it on the
/// user's PATH (HLD §20, Phase 7).
///
/// The sandboxed application cannot write to /usr/local/bin on its own. The
/// user chooses the folder in an Open panel, which grants access to just
/// that folder, and the command is installed as a symbolic link to the copy
/// in the application, so updating the application updates the command. If
/// the folder needs an administrator, the same command is offered to copy
/// into Terminal.
enum CommandLineTool {
    static let name = "quickzip"
    private static let installedFolderKey = "CommandLineToolFolder"

    /// QuickZip.app/Contents/Helpers/quickzip
    static var bundledURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
    }

    static var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: bundledURL.path)
    }

    enum State: Equatable {
        case notInstalled
        /// A link in `folder` to this copy of the application.
        case installed(folder: String)
        /// A link in `folder` to a copy that has moved or gone.
        case stale(folder: String)
    }

    /// Where to look for an earlier install: where the user put it last time,
    /// and the usual places.
    private static var candidateFolders: [String] {
        var folders: [String] = []
        if let saved = UserDefaults.standard.string(forKey: installedFolderKey) { folders.append(saved) }
        folders += ["/usr/local/bin", "/opt/homebrew/bin"]
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            folders.append(String(cString: home) + "/.local/bin")
        }
        return folders
    }

    static func state() -> State {
        for folder in candidateFolders {
            let link = (folder as NSString).appendingPathComponent(name)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { continue }
            return URL(fileURLWithPath: target).standardizedFileURL == bundledURL.standardizedFileURL
                ? .installed(folder: folder) : .stale(folder: folder)
        }
        return .notInstalled
    }

    /// The command to paste into Terminal, for folders the application cannot write to.
    static func installCommand(folder: String = "/usr/local/bin") -> String {
        "sudo mkdir -p '\(folder)' && sudo ln -sf '\(bundledURL.path)' '\(folder)/\(name)'"
    }

    /// Asks for a folder and links the command into it. Returns the folder
    /// installed in, or nil if the user cancelled.
    @MainActor
    static func installInChosenFolder() throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Install")
        panel.message = String(localized: "Choose a folder on your PATH, such as /usr/local/bin, to put the quickzip command in.")
        let preferred = URL(fileURLWithPath: "/usr/local/bin")
        if FileManager.default.fileExists(atPath: preferred.path) { panel.directoryURL = preferred }
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        try install(into: folder)
        return folder.path
    }

    static func install(into folder: URL) throws {
        guard isBundled else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: String(localized: "This copy of QuickZip does not contain the command-line tool.")])
        }
        let link = folder.appendingPathComponent(name)
        // Replace an earlier link, but never a real file.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "A file named “\(name)” is already in that folder, and it is not a link made by QuickZip."),
                ])
            }
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundledURL)
        UserDefaults.standard.set(folder.path, forKey: installedFolderKey)
    }

    static func uninstall() throws {
        guard case .installed(let folder) = state() else { return }
        try FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
        UserDefaults.standard.removeObject(forKey: installedFolderKey)
    }
}
