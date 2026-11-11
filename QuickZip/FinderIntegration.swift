import AppKit
import ArchiveKit
import SwiftUI
import UniformTypeIdentifiers

// Ways in and out of the application from Finder and the system
// (HLD §20, Phase 4): Services, Open Recent, remembered folders and tabs.

/// Receives "Browse with QuickZip" and "Uncompress All" from Finder's
/// Services menu.
final class ServiceProvider: NSObject {
    @objc func browseArchive(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let archives = urls.filter(ArchiveTypes.isOpenable)
        guard !archives.isEmpty else {
            error.pointee = String(localized: "Choose a ZIP archive to browse.") as NSString
            return
        }
        // Each archive opens in a window of its own, through the same path
        // as Finder's Open With.
        for url in archives {
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func uncompressAll(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let archives = urls.filter { ArchiveTypes.archiveExtensions.contains($0.pathExtension.lowercased()) }
        guard !archives.isEmpty else {
            error.pointee = String(localized: "Choose a ZIP archive to uncompress.") as NSString
            return
        }
        // Services are delivered on the main thread.
        MainActor.assumeIsolated {
            for url in archives { Uncompressor.shared.uncompress(url) }
        }
    }
}

/// "Uncompress All": extracts each archive chosen in Finder into a new
/// folder beside it, named after it (`archive.zip` → `archive`), without
/// opening a window. Uses the same extractor and limits as the browser.
@MainActor
final class Uncompressor {
    static let shared = Uncompressor()

    /// Archives being extracted, shown on the Dock icon.
    private var running = 0 {
        didSet { NSApp.dockTile.badgeLabel = running > 0 ? "\(running)" : nil }
    }

    func uncompress(_ archive: URL) {
        guard let destination = makeDestination(for: archive) else { return }
        let (folder, grant) = destination
        running += 1
        let options = ArchiveAutomation.Options(password: PasswordVault.password(for: archive))
        Task {
            defer {
                grant?.end()
                running -= 1
            }
            do {
                let result = try await ArchiveAutomation.extract(archive, to: folder, conflict: .keepBoth, options: options)
                finish(result, archive: archive, folder: folder)
            } catch ArchiveError.passwordRequired {
                Self.removeIfEmpty(folder)
                offerToOpen(archive)
            } catch {
                Self.removeIfEmpty(folder)
                Self.present(title: "“\(archive.lastPathComponent)” couldn’t be uncompressed", message: error.localizedDescription)
            }
        }
    }

    /// Creates the new folder beside the archive, and the folder access
    /// held while extracting into it; nil if the user declined.
    ///
    /// The sandbox lets QuickZip read the archive Finder handed over, but
    /// not write beside it until the user has granted that folder once.
    private func makeDestination(for archive: URL) -> (URL, FolderAccess.Grant?)? {
        let parent = archive.deletingLastPathComponent()
        let name = Self.folderName(for: archive)
        let quarantine = Quarantine.attribute(of: archive)
        let remembered = FolderAccess.grant(containing: parent)
        do {
            return (try Self.makeUniqueFolder(named: name, in: parent, quarantine: quarantine), remembered)
        } catch where remembered == nil && Self.isPermissionError(error) {
            guard let chosen = FolderAccess.request(toWriteIn: parent, for: archive) else { return nil }
            do {
                return (try Self.makeUniqueFolder(named: name, in: chosen.url, quarantine: quarantine), chosen)
            } catch {
                chosen.end()
                Self.present(title: "“\(archive.lastPathComponent)” couldn’t be uncompressed", message: error.localizedDescription)
                return nil
            }
        } catch {
            remembered?.end()
            Self.present(title: "“\(archive.lastPathComponent)” couldn’t be uncompressed", message: error.localizedDescription)
            return nil
        }
    }

    private func finish(_ result: ArchiveAutomation.ExtractResult, archive: URL, folder: URL) {
        let defaults = UserDefaults.standard
        let needsPassword = result.failures.contains { $0.kind == "passwordRequired" }
        if result.extracted.isEmpty {
            Self.removeIfEmpty(folder)
        } else if defaults.object(forKey: ArchiveBrowserModel.revealAfterExtractionKey) as? Bool ?? true {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }

        // As in the browser: only a complete extraction moves the archive
        // to the Trash.
        if defaults.bool(forKey: ArchiveBrowserModel.trashAfterExtractionKey),
           result.failures.isEmpty, result.skipped.isEmpty, !result.extracted.isEmpty {
            do {
                try FileManager.default.trashItem(at: archive, resultingItemURL: nil)
            } catch {
                Self.present(title: "“\(archive.lastPathComponent)” couldn’t be moved to the Trash", message: error.localizedDescription)
            }
        }

        if needsPassword {
            offerToOpen(archive)
        } else if !result.failures.isEmpty {
            let shown = result.failures.prefix(10).map { "\($0.path): \($0.error)" }
            var message = shown.joined(separator: "\n")
            if result.failures.count > shown.count {
                message += "\n" + String(localized: "…and \(result.failures.count - shown.count) more.")
            }
            let title: String.LocalizationValue = result.extracted.isEmpty
                ? "No items in “\(archive.lastPathComponent)” could be extracted"
                : "\(result.failures.count) items in “\(archive.lastPathComponent)” couldn’t be extracted"
            Self.present(title: title, message: message)
        }
    }

    /// Password-protected items are left for the browser window, which
    /// asks for the password.
    private func offerToOpen(_ archive: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(archive.lastPathComponent)” needs a password")
        alert.informativeText = String(localized: "Open it in QuickZip to enter the password and extract the protected items.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open([archive], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `archive.zip` → `archive`; `archive.tar.gz` → `archive`.
    static func folderName(for archive: URL) -> String {
        var name = archive.deletingPathExtension()
        if name.pathExtension.lowercased() == "tar" { name = name.deletingPathExtension() }
        let base = name.lastPathComponent
        return base.isEmpty ? archive.lastPathComponent + " " + String(localized: "Contents") : base
    }

    /// `name`, or `name 2`, `name 3`… when that already exists.
    private static func makeUniqueFolder(named name: String, in parent: URL, quarantine: Data?) throws -> URL {
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        if let quarantine {
            try Quarantine.apply(quarantine, to: folder)
        }
        return folder
    }

    private static func removeIfEmpty(_ folder: URL) {
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(EPERM) || underlying.code == Int(EACCES))
    }

    private static func present(title: String.LocalizationValue, message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

/// Folders the user has let QuickZip create folders in, remembered as
/// security-scoped bookmarks so that each is asked for only once.
@MainActor
enum FolderAccess {
    private static let key = "WritableFolders"

    /// Access to a folder, held until `end()`.
    struct Grant {
        let url: URL
        let isScoped: Bool

        func end() {
            if isScoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// A remembered folder that is `folder` or contains it, with access started.
    static func grant(containing folder: URL) -> Grant? {
        let target = folder.resolvingSymlinksInPath().path
        var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        defer { UserDefaults.standard.set(bookmarks, forKey: key) }
        for (path, data) in bookmarks where target == path || target.hasPrefix(path == "/" ? "/" : path + "/") {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                bookmarks[path] = nil
                continue
            }
            guard url.startAccessingSecurityScopedResource() else { continue }
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[path] = fresh
            }
            return Grant(url: url, isScoped: true)
        }
        return nil
    }

    /// Asks the user for permission to write in `folder`. They may choose
    /// another folder instead, which is then where the archive is
    /// uncompressed. Only `folder` itself, or a folder containing it, is
    /// remembered.
    static func request(toWriteIn folder: URL, for archive: URL) -> Grant? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Uncompress Here")
        panel.message = String(localized: "To uncompress “\(archive.lastPathComponent)” beside it, QuickZip needs your permission to create folders in “\(folder.lastPathComponent)”. Choose it once and QuickZip will remember it.")
        NSApp.activate()
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }

        let chosenPath = chosen.resolvingSymlinksInPath().path
        let target = folder.resolvingSymlinksInPath().path
        if target == chosenPath || target.hasPrefix(chosenPath == "/" ? "/" : chosenPath + "/"),
           let data = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
            bookmarks[chosenPath] = data
            UserDefaults.standard.set(bookmarks, forKey: key)
        }
        // The panel already grants access for as long as the app runs.
        return Grant(url: chosen, isScoped: chosen.startAccessingSecurityScopedResource())
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
}

/// The archives opened recently, for File → Open Recent. The system keeps
/// the list, including the access sandboxed apps need to reopen them.
@MainActor
final class RecentArchives: ObservableObject {
    static let shared = RecentArchives()

    @Published private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls = NSDocumentController.shared.recentDocumentURLs
    }

    /// Clears the menu and the folders remembered for each archive.
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        FolderMemory.clear()
        urls = []
    }

    /// Opens `url` in the focused window if it is empty, else in a new one.
    func open(_ url: URL, in browser: ArchiveBrowserModel?) {
        if let browser, !browser.hasArchive, !browser.isOpening {
            browser.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// The folder last shown in each archive, so reopening it returns there.
/// Keeps the most recent archives only.
enum FolderMemory {
    private static let key = "LastFolders"
    private static let orderKey = "LastFoldersOrder"
    static let limit = 200

    static func folder(for archive: URL) -> String? {
        let folders = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return folders?[archive.standardizedFileURL.path]
    }

    static func remember(_ folder: String, for archive: URL) {
        let id = archive.standardizedFileURL.path
        let defaults = UserDefaults.standard
        var folders = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        var order = defaults.stringArray(forKey: orderKey) ?? []
        folders[id] = folder
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit {
            folders[order.removeFirst()] = nil
        }
        defaults.set(folders, forKey: key)
        defaults.set(order, forKey: orderKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: orderKey)
    }
}

/// At most a few thumbnails are made at once, so scrolling through a folder
/// of large photos does not decompress them all together.
actor ThumbnailGate {
    static let shared = ThumbnailGate()

    private var available = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Lets a window join its neighbours as a tab when the setting asks for it,
/// and opens archives from inside archives in a tab of the window they came from.
struct WindowTabbing: NSViewRepresentable {
    static let opensInTabsKey = "OpensArchivesInTabs"
    let opensInTabs: Bool
    let model: ArchiveBrowserModel

    /// The window the next new window should become a tab of.
    @MainActor private static var pendingParent: NSWindow?

    @MainActor static func openNextWindowAsTab(of parent: NSWindow?) {
        pendingParent = parent
    }

    @MainActor final class Coordinator {
        /// Whether this view's window has had its one chance to become a
        /// tab of `pendingParent`.
        var hasConsideredPendingParent = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { apply(to: view.window, coordinator: coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window, coordinator: context.coordinator)
    }

    private func apply(to window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        model.hostWindow = window
        window.tabbingMode = opensInTabs ? .preferred : .automatic
        window.tabbingIdentifier = "QuickZipBrowser"
        MainActor.assumeIsolated {
            // Only a window appearing for the first time can be the new one.
            // Without this, whichever existing window re-rendered first took
            // the pending parent, and was moved into its tab group.
            guard !coordinator.hasConsideredPendingParent else { return }
            coordinator.hasConsideredPendingParent = true
            if let parent = Self.pendingParent, parent !== window, parent.isVisible,
               parent.tabbedWindows?.contains(window) != true {
                Self.pendingParent = nil
                parent.tabbingMode = .preferred
                parent.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
