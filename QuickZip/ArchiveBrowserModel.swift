import AppKit
import ArchiveKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One row of the file list: an item in the folder being shown.
struct FileRow: Identifiable {
    let node: ArchiveNode
    let name: String
    let size: UInt64
    let kind: String
    /// `distantPast` when the archive records no date, so rows can be sorted.
    let modified: Date
    /// For search results: the folder holding the item, relative to the
    /// folder being searched ("" when directly inside it).
    let location: String?
    /// How much smaller the item is in the archive than outside it: 0.62
    /// for an item stored in 38% of its size. Zero for items that gain
    /// nothing, and for empty ones.
    let saving: Double

    var id: ArchiveNode.ID { node.id }
}

/// What the main area shows: the sortable list or the size treemap.
enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case treemap

    var id: String { rawValue }
}

/// Compare With… (HLD §20, Phase 5): running, then its result.
enum ComparisonState {
    case running(name: String)
    case finished(name: String, result: ArchiveComparison)
}

/// Progress of "Export Checksums".
struct ChecksumExportStatus {
    let total: Int
    var completed = 0
}

/// What the preview pane shows for the current selection.
enum PreviewState: Equatable {
    case none
    /// The item can never be previewed, with the reason.
    case unavailable(String)
    /// The item is encrypted and no password has been entered.
    case needsPassword
    /// Large enough that it is only decompressed when asked for.
    case needsConfirmation(size: UInt64)
    case loading
    case ready(URL)
    case failed(String)
}

/// A running extraction, shown in the status bar.
struct ExtractionStatus {
    let totalEntries: Int
    /// Nil until the extractor first reports.
    var progress: ExtractionProgress?

    var fractionCompleted: Double { progress?.fractionCompleted ?? 0 }
    var completedEntries: Int { progress?.completedEntries ?? 0 }
}

/// Entries to extract with the same archive path removed from the front of
/// each: the path of the folder holding the items chosen.
struct ExtractionGroup {
    let prefix: String
    var entries: [ArchiveEntry]
}

/// An extraction waiting for the user to decide what to do about items that
/// already exist at the destination.
struct PendingExtraction {
    /// One group per folder the chosen items come from: one, except for a
    /// selection of search results.
    let groups: [ExtractionGroup]
    let destination: URL
    /// Top-level items of the extraction, for revealing them in Finder.
    let topLevelNames: [String]
    let conflictingNames: [String]
    /// Whether this is "Extract All", after which the archive may be
    /// moved to the Trash (Settings).
    var isWholeArchive = false
}

/// Items waiting to be added while the user decides what to do about names
/// already in the destination folder.
struct PendingAddition {
    let sources: [URL]
    let folderPath: String
    let conflictingNames: [String]
}

/// Items waiting for the user to confirm their deletion.
struct PendingDeletion {
    let nodes: [ArchiveNode]
    let archiveName: String

    var title: String {
        nodes.count == 1
            ? String(localized: "Delete “\(nodes[0].name)” from “\(archiveName)”?")
            : String(localized: "Delete \(nodes.count) items from “\(archiveName)”?")
    }
}

/// Where to return to after the archive is reopened.
private struct Restoration {
    let folderPath: String
    let selectedNames: [String]
}

struct BrowserAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    /// An alert whose text is fixed and localized.
    init(title: LocalizedStringResource, message: LocalizedStringResource) {
        self.title = String(localized: title)
        self.message = String(localized: message)
    }

    /// An alert whose message is already text, such as an error's
    /// description or a reason built elsewhere.
    init(title: LocalizedStringResource, verbatim message: String) {
        self.title = String(localized: title)
        self.message = message
    }
}

/// Verify Archive (HLD §18.1): running, then its report.
enum VerificationState {
    case running(checked: Int, total: Int)
    case finished(VerificationReport)
}

/// What happened to the archive file while it was open (HLD §18.3).
enum ExternalChange: Equatable {
    case modified
    case deleted
}

/// State of one browser window (HLD §3 "Archive Browser Layer", §15).
///
/// Runs on the main actor; parsing, decompression and extraction happen in
/// the archive engine, off the main actor. The model only ever talks to an
/// `ArchiveProvider`, never to ZIP-specific types beyond opening one.
@MainActor
@Observable
final class ArchiveBrowserModel {
    /// Entries larger than this are not decompressed for the preview pane
    /// until the user asks.
    static let automaticPreviewLimit: UInt64 = 256 << 20
    /// Search results beyond this many are counted but not listed.
    static let searchResultLimit = 5_000
    static let showsMacOSMetadataKey = "ShowsMacOSMetadata"
    static let suppressOpenWarningKey = "SuppressOpenCopyWarning"
    static let revealAfterExtractionKey = "RevealAfterExtraction"
    static let trashAfterExtractionKey = "TrashArchiveAfterExtraction"

    private(set) var archiveURL: URL?
    private(set) var tree: ArchiveTree?
    private(set) var warnings: [String] = []
    private(set) var isOpening = false
    /// How far a slow open (compressed tar, Apple Archive) has got, 0…1,
    /// once it can say.
    private(set) var openProgress: Double?
    private(set) var openError: String?
    /// Why the open archive can't be changed, or nil if it can.
    private(set) var editBlocker: String?
    /// What the archive is being changed for, while it is.
    private(set) var updateStatus: String?
    var pendingAddition: PendingAddition?
    var pendingDeletion: PendingDeletion?
    /// How names not marked as UTF-8 are decoded (View → Text Encoding).
    private(set) var filenameEncoding: FilenameEncoding = .automatic
    /// The legacy encoding `.automatic` settled on, if not CP437.
    private(set) var detectedFilenameEncoding: FilenameEncoding?
    /// Whether `__MACOSX` entries are listed (View menu). They are merged
    /// into the items they describe on extraction either way.
    private(set) var showsMacOSMetadata = UserDefaults.standard.bool(forKey: ArchiveBrowserModel.showsMacOSMetadataKey)
    private(set) var verification: VerificationState?
    /// Set when another application changes or deletes the archive.
    private(set) var externalChange: ExternalChange?

    /// The folder whose contents the file list shows.
    var currentFolderID: ArchiveNode.ID? {
        didSet {
            guard currentFolderID != oldValue else { return }
            if !isInstallingBrowsing { rememberCurrentFolder() }
            selection = []
            searchText = ""
            refreshRows()
        }
    }

    var selection: Set<ArchiveNode.ID> = [] {
        didSet {
            if selection != oldValue { updatePreview() }
        }
    }

    /// Lists the items at or below the current folder matching this text
    /// (see `ArchiveSearchIndex` for the syntax).
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            selection = []
            refreshRows()
        }
    }

    var sortOrder: [KeyPathComparator<FileRow>] = [KeyPathComparator(\FileRow.name)] {
        didSet { refreshRows() }
    }

    private(set) var rows: [FileRow] = []
    /// Matches for the search, including any beyond `searchResultLimit`.
    private(set) var searchMatchCount = 0
    private(set) var preview: PreviewState = .none
    private(set) var extraction: ExtractionStatus?
    var pendingExtraction: PendingExtraction?
    var alert: BrowserAlert?
    /// Drives the Quick Look panel (`quickLookPreview`).
    var quickLookURL: URL?
    var isInspectorPresented = true
    var viewMode: BrowserViewMode = .list

    /// What looks suspicious in the archive; nil while it is being analysed.
    private(set) var safetyReport: ArchiveSafetyReport?
    private(set) var safetySeverities: [ArchiveEntry.ID: SafetyFinding.Severity] = [:]
    var isSafetyReportPresented = false
    private(set) var isSafetyBannerDismissed = false
    /// SHA-256 of items the user asked for, by entry id.
    private(set) var sha256Values: [ArchiveEntry.ID: String] = [:]
    private(set) var sha256InProgress: ArchiveEntry.ID?
    private(set) var checksumExport: ChecksumExportStatus?
    /// Set once a password has been accepted for the open archive.
    private(set) var isUnlocked = false
    private(set) var hasSavedPassword = false
    var isPasswordPromptPresented = false
    private(set) var passwordFailure: String?
    private(set) var passwordPromptDetail = ""
    var comparison: ComparisonState?
    /// Whether the open archive is a temporary copy of one inside another
    /// archive, which is not saved back anywhere.
    private(set) var isTemporaryCopy = false

    @ObservationIgnored private var archive: (any ArchiveProvider)?
    /// Every entry, including hidden `__MACOSX` ones the tree leaves out.
    @ObservationIgnored private var entries: [ArchiveEntry] = []
    @ObservationIgnored private var nodesByID: [ArchiveNode.ID: ArchiveNode] = [:]
    @ObservationIgnored private var parentByID: [ArchiveNode.ID: ArchiveNode] = [:]
    @ObservationIgnored private var searchIndex: ArchiveSearchIndex?
    @ObservationIgnored private var previews = PreviewCache()
    /// Files for drags and copies, deleted with the archive.
    @ObservationIgnored private var exporter: ItemExporter?
    /// Copies opened in other applications, which may still be using them
    /// after the archive closes; deleted at the next launch.
    @ObservationIgnored private var openedCopies: ItemExporter?
    @ObservationIgnored private var presenter: ArchiveFilePresenter?
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var extractionTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var isInstallingBrowsing = false
    @ObservationIgnored private var thumbnails: [ArchiveEntry.ID: NSImage] = [:]
    @ObservationIgnored private var safetyTask: Task<Void, Never>?
    @ObservationIgnored private var checksumTask: Task<Void, Never>?
    /// The window showing this model, so a nested archive can open as its tab.
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private var passwordProbe: ArchiveEntry?
    @ObservationIgnored private var afterUnlock: (() -> Void)?
    @ObservationIgnored private var comparisonTask: Task<Void, Never>?
    @ObservationIgnored private var securityScopedURL: URL?

    // MARK: Derived state

    var hasArchive: Bool { tree != nil }

    func node(withID id: ArchiveNode.ID) -> ArchiveNode? { nodesByID[id] }

    var currentFolder: ArchiveNode? {
        currentFolderID.flatMap { nodesByID[$0] }
    }

    /// The folders above the current one, from the archive root down, for the
    /// toolbar's breadcrumbs.
    var currentFolderAncestors: [ArchiveNode] {
        var result: [ArchiveNode] = []
        var id = currentFolderID
        while let current = id, let parent = parentByID[current] {
            result.insert(parent, at: 0)
            id = parent.id
        }
        return result
    }

    var canGoToEnclosingFolder: Bool {
        currentFolderID.flatMap { parentByID[$0] } != nil
    }

    var selectedNodes: [ArchiveNode] {
        rows.map(\.node).filter { selection.contains($0.id) }
    }

    /// The selected item when exactly one is selected.
    var selectedNode: ArchiveNode? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return nodesByID[id]
    }

    var isExtracting: Bool { extraction != nil }

    var isUpdating: Bool { updateStatus != nil }

    var isVerifying: Bool {
        if case .running = verification { return true }
        return false
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The selected files that can be opened in another application.
    var openableNodes: [ArchiveNode] {
        selectedNodes.filter { !$0.isDirectory }
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArchiveTypes.openPanelTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        close()
        if url.startAccessingSecurityScopedResource() {
            // Kept for as long as the archive is open: entries are read lazily.
            securityScopedURL = url
        }
        archiveURL = url
        isOpening = true
        openProgress = nil
        openError = nil
        let encoding = filenameEncoding
        let includeMetadata = showsMacOSMetadata
        let reporter = ProgressReporter { [weak self] (fraction: Double) in self?.openProgress = fraction }
        openTask = Task {
            do {
                let loaded = try await Self.load(url, encoding: encoding, includeMacOSMetadata: includeMetadata) {
                    reporter.report($0, isFinal: $0 >= 1)
                }
                try Task.checkCancellation()
                install(loaded)
                watch(url)
                if !Self.isTemporary(url) {
                    RecentArchives.shared.note(url)
                    if let path = FolderMemory.folder(for: url) { showFolder(atPath: path) }
                }
            } catch is CancellationError {
                return
            } catch {
                openError = error.localizedDescription
            }
            isOpening = false
            openProgress = nil
        }
    }

    /// Stops a slow open and returns to the empty window.
    func cancelOpening() {
        close()
    }

    /// Opens the archive and builds its folder hierarchy, off the main actor.
    private nonisolated static func load(
        _ url: URL,
        encoding: FilenameEncoding,
        includeMacOSMetadata: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> LoadedArchive {
        let archive = try await ArchiveOpener.open(url, options: ArchiveOpenOptions(filenameEncoding: encoding), progress: progress)
        let entries = await archive.entries
        return LoadedArchive(
            archive: archive,
            entries: entries,
            warnings: await archive.warnings,
            detectedEncoding: (archive as? ZIPArchive)?.detectedFilenameEncoding,
            browsing: browsingData(entries, archiveName: url.lastPathComponent, includeMacOSMetadata: includeMacOSMetadata)
        )
    }

    /// The folder hierarchy, lookup tables and search index for `entries`.
    private nonisolated static func browsingData(
        _ entries: [ArchiveEntry],
        archiveName: String,
        includeMacOSMetadata: Bool
    ) -> BrowsingData {
        let tree = ArchiveTree(entries: entries, archiveName: archiveName, includeMacOSMetadata: includeMacOSMetadata)
        var nodes: [ArchiveNode.ID: ArchiveNode] = [:]
        var parents: [ArchiveNode.ID: ArchiveNode] = [:]
        var stack = [tree.root]
        while let node = stack.popLast() {
            nodes[node.id] = node
            for child in node.children {
                parents[child.id] = node
                stack.append(child)
            }
        }
        return BrowsingData(tree: tree, nodesByID: nodes, parentByID: parents, searchIndex: ArchiveSearchIndex(tree: tree))
    }

    private func install(_ loaded: LoadedArchive) {
        archive = loaded.archive
        entries = loaded.entries
        isTemporaryCopy = archiveURL.map { Self.isTemporary($0) } ?? false
        if isTemporaryCopy {
            editBlocker = String(localized: "it is a temporary copy opened from another archive, so changes would not be kept")
        } else if let url = archiveURL, ArchiveTypes.isDocument(url) {
            editBlocker = String(localized: "it is a document, which has to keep its items in a particular order")
        } else if let rewritable = loaded.archive as? any RewritableArchive {
            editBlocker = rewritable.rewriteBlocker
        } else {
            editBlocker = String(localized: "this format can be browsed and extracted from but not changed")
        }
        warnings = loaded.warnings
        detectedFilenameEncoding = loaded.detectedEncoding
        exporter = ItemExporter(archive: loaded.archive, purpose: "Drags")
        openedCopies = ItemExporter(archive: loaded.archive, purpose: "Opened")
        install(loaded.browsing)
        analyzeSafety(of: loaded.archive)
        clearPasswordState()
        unlockFromKeychain()
    }

    private func install(_ browsing: BrowsingData) {
        tree = browsing.tree
        nodesByID = browsing.nodesByID
        parentByID = browsing.parentByID
        searchIndex = browsing.searchIndex
        isInstallingBrowsing = true
        currentFolderID = browsing.tree.root.id
        isInstallingBrowsing = false
        refreshRows()
        // The folder and selection may be unchanged, so their observers
        // don't refresh the preview.
        updatePreview()
    }

    /// Goes to a folder remembered from the last time the archive was open,
    /// if it is still there.
    private func showFolder(atPath path: String) {
        guard !path.isEmpty, let node = tree?.node(atPath: path), node.isDirectory else { return }
        currentFolderID = node.id
    }

    private func rememberCurrentFolder() {
        guard let archiveURL, tree != nil, !isTemporaryCopy, let folder = currentFolder else { return }
        FolderMemory.remember(folder.path, for: archiveURL)
    }

    /// Closes the archive, stopping any work in progress and deleting its
    /// preview files.
    func close() {
        openTask?.cancel()
        previewTask?.cancel()
        extractionTask?.cancel()
        updateTask?.cancel()
        verificationTask?.cancel()
        safetyTask?.cancel()
        checksumTask?.cancel()
        comparisonTask?.cancel()
        openTask = nil
        previewTask = nil
        extractionTask = nil
        updateTask = nil
        verificationTask = nil
        safetyTask = nil
        checksumTask = nil
        comparisonTask = nil
        comparison = nil
        clearInsight()
        clearPasswordState()
        let previews = self.previews
        Task { await previews.removeAll() }
        self.previews = PreviewCache()
        if let exporter {
            Task { await exporter.removeAll() }
        }
        exporter = nil
        openedCopies = nil
        stopWatching()

        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        archive = nil
        entries = []
        archiveURL = nil
        tree = nil
        warnings = []
        detectedFilenameEncoding = nil
        editBlocker = nil
        updateStatus = nil
        pendingAddition = nil
        pendingDeletion = nil
        verification = nil
        externalChange = nil
        nodesByID = [:]
        parentByID = [:]
        searchIndex = nil
        currentFolderID = nil
        selection = []
        rows = []
        searchMatchCount = 0
        preview = .none
        extraction = nil
        pendingExtraction = nil
        quickLookURL = nil
        isOpening = false
        openError = nil
    }

    /// Reads the archive again, returning to the folder being shown, for
    /// example after another application changed it.
    func reload() {
        guard let archiveURL, !isUpdating, !isExtracting else {
            NSSound.beep()
            return
        }
        let restoration = Restoration(folderPath: currentFolder?.path ?? "", selectedNames: selectedNodes.map(\.name))
        reopen(archiveURL, then: restoration)
    }

    /// Reopens the same archive in place: the window keeps its contents
    /// until the new ones are ready, and the security scope is kept.
    private func reopen(_ url: URL, then restoration: Restoration?) {
        openTask?.cancel()
        previewTask?.cancel()
        verificationTask?.cancel()
        verification = nil
        quickLookURL = nil
        let encoding = filenameEncoding
        let includeMetadata = showsMacOSMetadata
        isOpening = true
        openTask = Task {
            do {
                let loaded = try await Self.load(url, encoding: encoding, includeMacOSMetadata: includeMetadata)
                try Task.checkCancellation()
                resetPreviews()
                install(loaded)
                externalChange = nil
                if let restoration { restore(restoration) }
            } catch is CancellationError {
                return
            } catch {
                alert = BrowserAlert(title: "“\(url.lastPathComponent)” couldn’t be reopened", verbatim: error.localizedDescription)
            }
            isOpening = false
        }
    }

    /// Entry ids change when the archive changes, so earlier preview and
    /// drag files no longer match.
    private func resetPreviews() {
        let previews = self.previews
        Task { await previews.removeAll() }
        self.previews = PreviewCache()
        if let exporter {
            Task { await exporter.removeAll() }
        }
        preview = .none
    }

    // MARK: View options

    /// View → Text Encoding: reopens the archive with names decoded as
    /// `encoding`. Paths change with the encoding, so the window returns to
    /// the top of the archive.
    func setFilenameEncoding(_ encoding: FilenameEncoding) {
        guard encoding != filenameEncoding else { return }
        guard !isUpdating, !isExtracting else {
            NSSound.beep()
            return
        }
        filenameEncoding = encoding
        guard let archiveURL, hasArchive else { return }
        reopen(archiveURL, then: nil)
    }

    /// View → Show macOS Metadata: lists or hides `__MACOSX` entries.
    func setShowsMacOSMetadata(_ shows: Bool) {
        guard shows != showsMacOSMetadata else { return }
        guard !isUpdating, !isExtracting else {
            NSSound.beep()
            return
        }
        showsMacOSMetadata = shows
        UserDefaults.standard.set(shows, forKey: Self.showsMacOSMetadataKey)
        guard let archiveURL, hasArchive else { return }
        let restoration = Restoration(folderPath: currentFolder?.path ?? "", selectedNames: selectedNodes.map(\.name))
        let entries = self.entries
        let name = archiveURL.lastPathComponent
        Task {
            let browsing = await Task.detached {
                Self.browsingData(entries, archiveName: name, includeMacOSMetadata: shows)
            }.value
            // Only if nothing has replaced the archive meanwhile.
            guard self.archiveURL == archiveURL, self.showsMacOSMetadata == shows else { return }
            install(browsing)
            restore(restoration)
        }
    }

    // MARK: Watching the archive file

    private func watch(_ url: URL) {
        stopWatching()
        let presenter = ArchiveFilePresenter(url: url)
        // Opening a file makes the system write extended attributes (last
        // used date, Spotlight metadata), which the presenter reports as
        // changes. Only a different size or modification date is one.
        var signature = Self.fileSignature(of: url)
        presenter.onChange = { [weak self] change in
            guard let self, !self.isUpdating else { return }
            if change == .modified {
                let current = Self.fileSignature(of: self.archiveURL ?? url)
                guard current != signature else { return }
                signature = current
            }
            self.externalChange = change
        }
        presenter.onMove = { [weak self] newURL in
            self?.archiveURL = newURL
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    private static func fileSignature(of url: URL) -> [AnyHashable] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return [values?.fileSize, values?.contentModificationDate]
    }

    private func stopWatching() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenter = nil
    }

    func dismissExternalChange() {
        externalChange = nil
    }

    // MARK: Navigation

    /// Double-click or Return, as in Finder: a folder is opened in the
    /// window, files are opened in their default applications.
    func activate(_ ids: Set<ArchiveNode.ID>) {
        let nodes = ids.compactMap { nodesByID[$0] }
        if nodes.count == 1, let folder = nodes.first, folder.isDirectory {
            currentFolderID = folder.id
            return
        }
        if nodes.count == 1, let node = nodes.first, isNestedArchive(node) {
            openNestedArchive(node)
            return
        }
        selection = ids
        openInDefaultApplication()
    }

    func goToEnclosingFolder() {
        guard let current = currentFolderID, let parent = parentByID[current] else { return }
        currentFolderID = parent.id
        selection = [current]
    }

    private func refreshRows() {
        guard let folder = currentFolder else {
            rows = []
            searchMatchCount = 0
            return
        }
        let nodes: [ArchiveNode]
        if isSearching, let searchIndex {
            // Searches everything below the folder being shown, as Finder
            // does when searching a folder (HLD §12).
            let matches = searchIndex.search(searchText, in: folder)
            searchMatchCount = matches.count
            nodes = Array(matches.prefix(Self.searchResultLimit))
        } else {
            searchMatchCount = 0
            nodes = folder.children
        }
        let isSearching = self.isSearching
        let folderDepth = folder.path.isEmpty ? 0 : folder.path.split(separator: "/").count
        rows = nodes
            .map { node in
                FileRow(
                    node: node,
                    name: node.name,
                    size: node.totalUncompressedSize,
                    kind: FileTypes.kind(of: node),
                    modified: node.entry?.modificationDate ?? .distantPast,
                    location: isSearching
                        ? node.path.split(separator: "/").dropFirst(folderDepth).dropLast().joined(separator: "/")
                        : nil,
                    saving: node.compressionRatio.map { max(1 - $0, 0) } ?? 0
                )
            }
            .sorted(using: sortOrder)
    }

    // MARK: Preview

    /// Decompresses the selected file for the preview pane, unless it is too
    /// large to do without asking.
    func updatePreview(force: Bool = false) {
        previewTask?.cancel()
        previewTask = nil
        guard let node = selectedNode, !node.isDirectory, let entry = node.entry, let archive else {
            preview = .none
            return
        }
        if let reason = Self.reasonPreviewUnavailable(entry) {
            preview = .unavailable(reason)
            return
        }
        if entry.needsPassword && !isUnlocked {
            preview = .needsPassword
            return
        }
        if !force && entry.uncompressedSize > Self.automaticPreviewLimit {
            preview = .needsConfirmation(size: entry.uncompressedSize)
            return
        }
        preview = .loading
        let previews = self.previews
        previewTask = Task {
            do {
                let url = try await previews.file(for: entry, in: archive)
                try Task.checkCancellation()
                preview = .ready(url)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { preview = .failed(error.localizedDescription) }
            }
        }
    }

    /// Shows the selected file in the Quick Look panel (Space).
    func quickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let node = selectedNode, !node.isDirectory, let entry = node.entry, let archive else {
            NSSound.beep()
            return
        }
        if let reason = Self.reasonPreviewUnavailable(entry) {
            alert = BrowserAlert(title: "“\(entry.name)” can’t be previewed", verbatim: reason)
            return
        }
        if case .ready(let url) = preview {
            quickLookURL = url
            return
        }
        if entry.needsPassword && !isUnlocked {
            requestPassword(for: node) { [weak self] in self?.quickLook() }
            return
        }
        let previews = self.previews
        Task {
            do {
                let url = try await previews.file(for: entry, in: archive)
                // Only if the selection has not moved on meanwhile.
                if selectedNode?.id == node.id { quickLookURL = url }
            } catch is CancellationError {
                return
            } catch {
                alert = BrowserAlert(title: "“\(entry.name)” can’t be previewed", verbatim: error.localizedDescription)
            }
        }
    }

    // MARK: Opening items in other applications

    /// Opens the selected files in their default applications, as Finder's
    /// Open does (HLD §18.3). Each is a read-only copy: the first time, the
    /// user is told that changes are not saved back into the archive.
    func openInDefaultApplication() {
        let nodes = openableNodes
        guard !nodes.isEmpty, let openedCopies, let tree else {
            NSSound.beep()
            return
        }
        for node in nodes {
            if let entry = node.entry, let reason = Self.reasonPreviewUnavailable(entry) {
                alert = BrowserAlert(title: "“\(node.name)” can’t be opened", verbatim: reason)
                return
            }
        }
        guard confirmOpeningCopies(of: nodes) else { return }
        let items = nodes.map { transferItem(for: $0, in: tree, exporter: openedCopies) }
        let opened = items.flatMap(\.entries)
        if !isUnlocked, opened.contains(where: \.needsPassword) {
            requestPassword { [weak self] in self?.openCopies(of: items, from: openedCopies) }
            return
        }
        openCopies(of: items, from: openedCopies)
    }

    private func openCopies(of items: [ArchiveItemTransfer], from openedCopies: ItemExporter) {
        Task {
            for item in items {
                do {
                    let url = try await openedCopies.export(item)
                    // Discourages editing a copy whose changes would be lost.
                    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
                    NSWorkspace.shared.open(url)
                } catch is CancellationError {
                    return
                } catch {
                    alert = BrowserAlert(title: "“\(item.name)” couldn’t be opened", verbatim: error.localizedDescription)
                }
            }
        }
    }

    /// Explains, until the user asks not to be told again, that opened
    /// items are copies.
    private func confirmOpeningCopies(of nodes: [ArchiveNode]) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.suppressOpenWarningKey) else { return true }
        let alert = NSAlert()
        alert.messageText = nodes.count == 1
            ? String(localized: "“\(nodes[0].name)” will open as a read-only copy")
            : String(localized: "\(nodes.count) items will open as read-only copies")
        alert.informativeText = archiveURL.map {
            String(localized: "Changes made in other applications aren’t saved back into “\($0.lastPathComponent)”. To keep changes, save the file somewhere else.")
        } ?? String(localized: "Changes made in other applications aren’t saved back into the archive. To keep changes, save the file somewhere else.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: Self.suppressOpenWarningKey)
        }
        return response == .alertFirstButtonReturn
    }

    // MARK: Drag and drop, copy and paste

    /// The selected items, promised to Finder when dragged or copied
    /// (HLD §11). Nothing is extracted until Finder asks for them.
    var selectedTransferItems: [ArchiveItemTransfer] {
        guard hasArchive else { return [] }
        return outermost(selectedNodes).map { transferItem(for: $0, in: tree, exporter: exporter) }
    }

    /// `nodes` without any inside another of them, which a search can
    /// select together with its folder; they come along with the folder.
    private func outermost(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { node in
            var id = node.id
            while let parent = parentByID[id] {
                if ids.contains(parent.id) { return false }
                id = parent.id
            }
            return true
        }
    }

    /// The item to drag for a row: the whole selection is dragged when the
    /// row is part of it, which the table handles by asking for each row.
    func transferItem(for node: ArchiveNode) -> ArchiveItemTransfer {
        transferItem(for: node, in: tree, exporter: exporter)
    }

    private func transferItem(for node: ArchiveNode, in tree: ArchiveTree?, exporter: ItemExporter?) -> ArchiveItemTransfer {
        ArchiveItemTransfer(
            name: node.name,
            isDirectory: node.isDirectory,
            entries: tree?.entries(under: node) ?? [],
            prefix: (node.path as NSString).deletingLastPathComponent,
            exporter: exporter
        )
    }

    /// Whether `urls` were dropped from this window's own drags, which must
    /// not be added back into the archive.
    func isOwnExport(_ urls: [URL]) -> Bool {
        let root = ItemExporter.rootDirectory.standardizedFileURL.path + "/"
        return urls.contains { $0.standardizedFileURL.path.hasPrefix(root) }
    }

    private static func reasonPreviewUnavailable(_ entry: ArchiveEntry) -> String? {
        if entry.type == .symlink {
            return String(localized: "It is a symbolic link.")
        }
        if entry.isEncrypted && entry.encryption?.isSupported != true {
            return String(localized: "It uses an encryption method that is not supported.")
        }
        if !entry.compressionMethod.isSupported {
            return String(localized: "It is compressed with \(entry.compressionMethod.description), which is not supported.")
        }
        return nil
    }

    // MARK: Editing

    /// Whether items can be added to or deleted from the archive now.
    var canEdit: Bool { hasArchive && !isExtracting && !isUpdating && !isVerifying && editBlocker == nil }

    var canDeleteSelection: Bool { canEdit && !selection.isEmpty }

    func presentAddPanel() {
        guard let folder = currentFolder, checkEditable() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        let folderName = folder.path.isEmpty ? archiveURL?.lastPathComponent ?? "" : folder.name
        panel.message = String(localized: "Choose items to add to “\(folderName)”.")
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// Adds files and folders to the folder being shown, asking first if
    /// any of their names are already there.
    func add(_ urls: [URL]) {
        guard let folder = currentFolder, !urls.isEmpty, checkEditable() else { return }
        let archivePath = archiveURL?.standardizedFileURL.path
        let sources = urls.filter { $0.standardizedFileURL.path != archivePath }
        guard !sources.isEmpty else {
            alert = BrowserAlert(title: "An archive can’t be added to itself", message: "Choose other items to add.")
            return
        }
        let existing = Set(folder.children.map { $0.name.lowercased() })
        let request = PendingAddition(
            sources: sources,
            folderPath: folder.path,
            conflictingNames: sources.map(\.lastPathComponent).filter { existing.contains($0.lowercased()) }
        )
        if request.conflictingNames.isEmpty {
            runAddition(request, conflictPolicy: .keepBoth)
        } else {
            pendingAddition = request
        }
    }

    /// Continues an addition once the user has chosen how to handle names
    /// already in the folder; nil cancels it.
    func resolvePendingAddition(with policy: ExtractionOptions.ConflictPolicy?) {
        guard let request = pendingAddition else { return }
        pendingAddition = nil
        if let policy { runAddition(request, conflictPolicy: policy) }
    }

    private func runAddition(_ request: PendingAddition, conflictPolicy: ExtractionOptions.ConflictPolicy) {
        guard let tree, let folder = tree.node(atPath: request.folderPath) else { return }
        var taken = Set(folder.children.map { $0.name.lowercased() })
        var removing = Set<ArchiveEntry.ID>()
        var additions: [ArchiveAddition] = []
        var addedNames: [String] = []
        for source in request.sources {
            var name = source.lastPathComponent
            if let existing = folder.children.first(where: { $0.name.lowercased() == name.lowercased() }) {
                switch conflictPolicy {
                case .skip, .fail:
                    continue
                case .replace:
                    removing.formUnion(entryIDs(under: [existing]))
                case .keepBoth:
                    name = Self.uniqueName(for: source, taken: taken)
                }
            }
            taken.insert(name.lowercased())
            addedNames.append(name)
            additions.append(ArchiveAddition(source: source, path: folder.path.isEmpty ? name : folder.path + "/" + name))
        }
        guard !additions.isEmpty else { return }
        runUpdate(
            removing: removing,
            adding: additions,
            sources: request.sources,
            status: additions.count == 1
                ? String(localized: "Adding “\(addedNames[0])”…")
                : String(localized: "Adding \(additions.count) items…"),
            then: Restoration(folderPath: folder.path, selectedNames: addedNames)
        )
    }

    /// "name 2.ext", "name 3.ext", …: the first not already taken.
    private static func uniqueName(for source: URL, taken: Set<String>) -> String {
        let name = source.lastPathComponent
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = isFolder ? "" : source.pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// Asks to confirm deleting the selected items from the archive.
    func requestDeleteSelection() {
        guard checkEditable() else { return }
        let nodes = selectedNodes
        guard !nodes.isEmpty, let archiveURL else {
            NSSound.beep()
            return
        }
        pendingDeletion = PendingDeletion(nodes: nodes, archiveName: archiveURL.lastPathComponent)
    }

    func confirmDeletion() {
        guard let request = pendingDeletion, let folder = currentFolder else { return }
        pendingDeletion = nil
        runUpdate(
            removing: entryIDs(under: request.nodes),
            adding: [],
            sources: [],
            status: request.nodes.count == 1
                ? String(localized: "Deleting “\(request.nodes[0].name)”…")
                : String(localized: "Deleting \(request.nodes.count) items…"),
            then: Restoration(folderPath: folder.path, selectedNames: [])
        )
    }

    /// Every entry at or below `nodes`, plus their hidden `__MACOSX`
    /// companions, which would otherwise be left behind.
    private func entryIDs(under nodes: [ArchiveNode]) -> Set<ArchiveEntry.ID> {
        var ids = Set<ArchiveEntry.ID>()
        for node in nodes {
            ids.formUnion(tree?.entries(under: node).map(\.id) ?? [])
            let path = node.path
            let directory = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let metadata = "__MACOSX/" + (directory.isEmpty ? "" : directory + "/") + "._" + name
            let metadataFolder = "__MACOSX/" + path
            for entry in entries where entry.path == metadata || entry.path == metadataFolder
                || entry.path.hasPrefix(metadataFolder + "/") {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    /// True if the archive can be changed now; otherwise explains why not.
    private func checkEditable() -> Bool {
        guard hasArchive else { return false }
        if let editBlocker, let archiveURL {
            alert = BrowserAlert(
                title: "“\(archiveURL.lastPathComponent)” can’t be changed",
                verbatim: String(localized: "Archives are only changed when they can be read completely, but \(editBlocker). You can still extract its contents.")
            )
            return false
        }
        if isExtracting || isUpdating || isVerifying {
            NSSound.beep()
            return false
        }
        return true
    }

    /// Writes the changed archive to a temporary file, then swaps it in for
    /// the original and reloads it. The original is untouched until the new
    /// archive is complete and verified.
    private func runUpdate(
        removing: Set<ArchiveEntry.ID>,
        adding: [ArchiveAddition],
        sources: [URL],
        status: String,
        then restoration: Restoration
    ) {
        guard let archive = archive as? any RewritableArchive, let archiveURL, !isUpdating else { return }
        updateStatus = status
        previewTask?.cancel()
        quickLookURL = nil
        let presenter = self.presenter
        let encoding = filenameEncoding
        let includeMetadata = showsMacOSMetadata
        updateTask = Task {
            do {
                try await Self.update(
                    archive, at: archiveURL, removing: removing, adding: adding, sources: sources, presenter: presenter
                )
                resetPreviews()
                // Reloaded in place, so the window keeps showing the old
                // contents until the new ones are ready.
                install(try await Self.load(archiveURL, encoding: encoding, includeMacOSMetadata: includeMetadata))
                restore(restoration)
            } catch is CancellationError {
            } catch {
                alert = BrowserAlert(title: "“\(archiveURL.lastPathComponent)” couldn’t be changed", verbatim: error.localizedDescription)
            }
            updateStatus = nil
            updateTask = nil
        }
    }

    private nonisolated static func update(
        _ archive: any RewritableArchive,
        at archiveURL: URL,
        removing: Set<ArchiveEntry.ID>,
        adding: [ArchiveAddition],
        sources: [URL],
        presenter: ArchiveFilePresenter?
    ) async throws {
        // Items from the open panel or a drag are only readable while
        // their security scope is held.
        let accessed = sources.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        let workDirectory = (try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: archiveURL,
            create: true
        )) ?? fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let newArchive = workDirectory.appendingPathComponent(archiveURL.lastPathComponent)
        try await archive.rewrite(to: newArchive, removing: removing, adding: adding)
        try Task.checkCancellation()
        // Coordinated, so other applications presenting the archive hear
        // about the change and this window's own presenter does not.
        try coordinateWriting(archiveURL, presenter: presenter) { archiveURL in
            try put(newArchive, at: archiveURL)
        }
    }

    private nonisolated static func coordinateWriting(
        _ url: URL,
        presenter: ArchiveFilePresenter?,
        _ write: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            do {
                try write(url)
            } catch {
                writeError = error
            }
        }
        if let error = writeError ?? coordinationError.map({ $0 as Error }) { throw error }
    }

    /// Puts the finished archive in place of the original.
    private nonisolated static func put(_ newArchive: URL, at archiveURL: URL) throws {
        let fileManager = FileManager.default
        do {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: newArchive)
        } catch {
            // The sandbox may grant access to the archive alone, not to its
            // folder, which swapping files needs. Copy the finished and
            // verified archive over the original instead.
            do {
                try overwrite(archiveURL, with: newArchive)
            } catch {
                let rescued = try? rescue(newArchive)
                var message = String(localized: "“\(archiveURL.lastPathComponent)” could not be updated and may be damaged: \(error.localizedDescription)")
                if let rescued {
                    message += " " + String(localized: "A complete copy of the updated archive was saved to “\(rescued.path)”.")
                }
                throw ArchiveError.io(message)
            }
        }
    }

    private nonisolated static func overwrite(_ destination: URL, with source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    /// Moves an updated archive that could not be put in place somewhere
    /// it survives, so the changes are not lost.
    private nonisolated static func rescue(_ archive: URL) throws -> URL {
        let fileManager = FileManager.default
        let folder = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Recovered Archives", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString.prefix(8)) \(archive.lastPathComponent)")
        try fileManager.moveItem(at: archive, to: destination)
        return destination
    }

    /// Returns to the folder being shown (or the nearest one still there)
    /// and selects the named items.
    private func restore(_ restoration: Restoration) {
        guard let tree else { return }
        var path = restoration.folderPath
        var folder = tree.node(atPath: path)
        while folder?.isDirectory != true, !path.isEmpty {
            path = (path as NSString).deletingLastPathComponent
            folder = tree.node(atPath: path)
        }
        guard let folder else { return }
        currentFolderID = folder.id
        let names = Set(restoration.selectedNames)
        selection = Set(folder.children.filter { names.contains($0.name) }.map(\.id))
        updatePreview()
    }

    // MARK: Extraction

    /// Extracts the selected items, or the whole folder being shown when
    /// nothing is selected.
    func extractSelection() {
        guard let folder = currentFolder else { return }
        let nodes = selectedNodes.isEmpty ? (isSearching ? rows.map(\.node) : folder.children) : selectedNodes
        beginExtraction(of: nodes, intoNewFolderNamed: nil)
    }

    /// Extracts the complete archive into a new folder named after it, as
    /// Archive Utility does.
    ///
    /// An archive whose only top-level item is a folder is extracted
    /// directly, rather than into a folder of the same name inside which
    /// that folder would sit (HLD §20, "Smart extraction defaults").
    func extractAll() {
        guard let tree, let archiveURL else { return }
        let top = tree.root.children
        if top.count == 1, top[0].isDirectory {
            beginExtraction(of: top, intoNewFolderNamed: nil, isWholeArchive: true)
        } else {
            beginExtraction(
                of: top,
                intoNewFolderNamed: archiveURL.deletingPathExtension().lastPathComponent,
                isWholeArchive: true
            )
        }
    }

    var canExtract: Bool { hasArchive && !isExtracting && !isUpdating }

    /// Each item is extracted without the folders above it, so search
    /// results from different folders all land side by side.
    private func beginExtraction(of nodes: [ArchiveNode], intoNewFolderNamed folderName: String?, isWholeArchive: Bool = false) {
        let nodes = outermost(nodes)
        guard let tree, let archive, !isExtracting, !nodes.isEmpty else { return }
        if !isUnlocked, nodes.contains(where: { tree.entries(under: $0).contains(where: \.needsPassword) }) {
            requestPassword { [weak self] in
                self?.beginExtraction(of: nodes, intoNewFolderNamed: folderName, isWholeArchive: isWholeArchive)
            }
            return
        }
        guard var destination = chooseDestination(itemCount: nodes.count) else { return }

        if let folderName {
            do {
                destination = try makeUniqueFolder(named: folderName, in: destination, quarantine: archive.sourceQuarantine)
            } catch {
                alert = BrowserAlert(title: "The archive couldn’t be extracted", verbatim: error.localizedDescription)
                return
            }
        }

        var groups: [ExtractionGroup] = []
        var groupIndexByPrefix: [String: Int] = [:]
        for node in nodes {
            let prefix = (node.path as NSString).deletingLastPathComponent
            if let index = groupIndexByPrefix[prefix] {
                groups[index].entries += tree.entries(under: node)
            } else {
                groupIndexByPrefix[prefix] = groups.count
                groups.append(ExtractionGroup(prefix: prefix, entries: tree.entries(under: node)))
            }
        }

        let names = nodes.map(\.name)
        let request = PendingExtraction(
            groups: groups,
            destination: destination,
            topLevelNames: names,
            conflictingNames: names.filter {
                FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path)
            },
            isWholeArchive: isWholeArchive
        )
        if request.conflictingNames.isEmpty {
            runExtraction(request, conflictPolicy: .keepBoth)
        } else {
            pendingExtraction = request
        }
    }

    /// Continues an extraction once the user has chosen how to handle
    /// existing items; nil cancels it.
    func resolvePendingExtraction(with policy: ExtractionOptions.ConflictPolicy?) {
        guard let request = pendingExtraction else { return }
        pendingExtraction = nil
        if let policy { runExtraction(request, conflictPolicy: policy) }
    }

    func cancelExtraction() {
        extractionTask?.cancel()
    }

    private func runExtraction(_ request: PendingExtraction, conflictPolicy: ExtractionOptions.ConflictPolicy) {
        guard let archive else { return }
        let extractor: ArchiveExtractor
        do {
            extractor = try ArchiveExtractor(
                destination: request.destination,
                options: ExtractionOptions(conflictPolicy: conflictPolicy)
            )
        } catch {
            alert = BrowserAlert(title: "The items couldn’t be extracted", verbatim: error.localizedDescription)
            return
        }

        let totalEntries = request.groups.reduce(0) { $0 + $1.entries.count }
        extraction = ExtractionStatus(totalEntries: totalEntries)
        let reporter = ProgressReporter { [weak self] (progress: ExtractionProgress) in
            self?.extraction?.progress = progress
        }
        extractionTask = Task {
            do {
                var result = ExtractionResult()
                // Progress across all groups: what earlier groups completed,
                // plus the current group's own progress.
                var completedEntries = 0
                var completedBytes: UInt64 = 0
                let totalBytes = Self.fileBytes(request.groups.flatMap(\.entries))
                for group in request.groups {
                    let baseEntries = completedEntries
                    let baseBytes = completedBytes
                    let groupResult = try await extractor.extract(
                        group.entries,
                        from: archive,
                        removingPrefix: group.prefix,
                        progress: { progress in
                            reporter.report(ExtractionProgress(
                                completedEntries: baseEntries + progress.completedEntries,
                                totalEntries: totalEntries,
                                completedBytes: Self.saturatingSum(baseBytes, progress.completedBytes),
                                totalBytes: totalBytes
                            ), isFinal: baseEntries + progress.completedEntries == totalEntries)
                        }
                    )
                    completedEntries += group.entries.count
                    completedBytes = Self.saturatingSum(completedBytes, Self.fileBytes(group.entries))
                    result.extracted += groupResult.extracted
                    result.skipped += groupResult.skipped
                    result.failures += groupResult.failures
                }
                extraction = nil
                finishExtraction(result, request: request, extractor: extractor)
            } catch is CancellationError {
                extraction = nil
            } catch {
                extraction = nil
                alert = BrowserAlert(title: "The items couldn’t be extracted", verbatim: error.localizedDescription)
            }
            extractionTask = nil
        }
    }

    /// The declared size of the files among `entries`. Declared sizes are
    /// untrusted, so the sum saturates rather than overflowing.
    private nonisolated static func fileBytes(_ entries: [ArchiveEntry]) -> UInt64 {
        entries.reduce(0) { saturatingSum($0, $1.type == .file ? $1.uncompressedSize : 0) }
    }

    private nonisolated static func saturatingSum(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    // MARK: Passwords (HLD §20, Phase 5)

    /// Items that need a password the archive has not been given.
    var lockedItemCount: Int {
        isUnlocked ? 0 : entries.filter { $0.needsPassword && $0.type != .directory }.count
    }

    var hasEncryptedItems: Bool { entries.contains { $0.needsPassword && $0.type != .directory } }

    private func clearPasswordState() {
        isUnlocked = false
        hasSavedPassword = archiveURL.map { PasswordVault.hasPassword(for: $0) } ?? false
        isPasswordPromptPresented = false
        passwordFailure = nil
        passwordProbe = nil
        afterUnlock = nil
    }

    /// The cheapest encrypted entry to test a password on: small ones can
    /// be read in full, which settles it for every scheme.
    private func probeEntry(preferring node: ArchiveNode? = nil) -> ArchiveEntry? {
        if let entry = node?.entry, entry.needsPassword { return entry }
        return entries.filter { $0.needsPassword && $0.type != .directory }.min { $0.uncompressedSize < $1.uncompressedSize }
    }

    /// Tries the password saved in the Keychain, if there is one.
    private func unlockFromKeychain() {
        guard let archive, let archiveURL, let probe = probeEntry(),
              let saved = PasswordVault.password(for: archiveURL) else { return }
        Task {
            if await archive.checkPassword(saved, for: probe) != false {
                await archive.setPassword(saved)
                isUnlocked = true
                updatePreview()
            }
        }
    }

    /// Asks for the password (Archive → Enter Password…), then carries on
    /// with `then`. Without a password, `then` is never called.
    func requestPassword(for node: ArchiveNode? = nil, then action: (() -> Void)? = nil) {
        guard let probe = probeEntry(preferring: node ?? selectedNode) else { return }
        passwordProbe = probe
        afterUnlock = action
        passwordFailure = nil
        passwordPromptDetail = hasEncryptedItems
            ? String(localized: "Items in this archive are encrypted with \(probe.encryption?.description ?? "a password").")
            : ""
        isPasswordPromptPresented = true
    }

    func cancelPasswordPrompt() {
        isPasswordPromptPresented = false
        afterUnlock = nil
        passwordProbe = nil
    }

    /// Checks `password` against the item the prompt was raised for. Returns
    /// whether it was accepted; the sheet stays up with a message if not.
    func submitPassword(_ password: String, remember: Bool) async -> Bool {
        guard let archive, let probe = passwordProbe else { return false }
        let accepted = await archive.checkPassword(password, for: probe)
        guard accepted != false else {
            passwordFailure = String(localized: "That password doesn’t open this item. Try again.")
            return false
        }
        await archive.setPassword(password)
        isUnlocked = true
        passwordFailure = nil
        if remember, let archiveURL {
            hasSavedPassword = PasswordVault.save(password, for: archiveURL)
        }
        isPasswordPromptPresented = false
        let action = afterUnlock
        afterUnlock = nil
        passwordProbe = nil
        updatePreview(force: true)
        action?()
        return true
    }

    func forgetSavedPassword() {
        guard let archiveURL else { return }
        PasswordVault.delete(for: archiveURL)
        hasSavedPassword = false
    }

    /// Runs `action` now if nothing in `entries` needs a password that has
    /// not been entered; otherwise asks for it first, and drops the action
    /// if the user declines.
    private func withPassword(for entries: [ArchiveEntry], _ action: @escaping () -> Void) {
        if !isUnlocked, entries.contains(where: \.needsPassword) {
            requestPassword(for: nil, then: action)
        } else {
            action()
        }
    }

    // MARK: Nested archives

    static func isTemporary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(ItemExporter.rootDirectory.standardizedFileURL.path + "/")
    }

    /// Whether `node` is an archive this application can open from inside
    /// another.
    func isNestedArchive(_ node: ArchiveNode) -> Bool {
        guard !node.isDirectory, let entry = node.entry, entry.type == .file else { return false }
        return ArchiveTypes.openableExtensions.contains(entry.pathExtension)
    }

    /// Opens a ZIP held inside this archive in a new tab, from a temporary
    /// copy that is deleted at the next launch.
    func openNestedArchive(_ node: ArchiveNode) {
        guard let openedCopies, let tree, let entry = node.entry else { return }
        withPassword(for: [entry]) { [weak self] in
            guard let self else { return }
            let item = self.transferItem(for: node, in: tree, exporter: openedCopies)
            Task {
                do {
                    let url = try await openedCopies.export(item)
                    WindowTabbing.openNextWindowAsTab(of: self.hostWindow ?? NSApp.keyWindow)
                    _ = try? await NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
                } catch is CancellationError {
                    return
                } catch {
                    self.alert = BrowserAlert(title: "“\(node.name)” couldn’t be opened", verbatim: error.localizedDescription)
                }
            }
        }
    }

    // MARK: Compare

    /// Compare With…: asks for an archive or a folder, then lists what
    /// differs, without decompressing anything.
    func presentComparePanel() {
        guard hasArchive, comparison == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ArchiveTypes.openPanelTypes + [.folder]
        panel.prompt = String(localized: "Compare")
        panel.message = String(localized: "Choose an archive or a folder to compare with “\(archiveURL?.lastPathComponent ?? "")”.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        compare(with: url)
    }

    func compare(with url: URL) {
        let mine = entries
        let name = url.lastPathComponent
        comparison = .running(name: name)
        comparisonTask = Task {
            do {
                let other: ArchiveComparison.Other
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                    other = .folder(url)
                } else {
                    other = .archive(await (try await ArchiveOpener.open(url)).entries)
                }
                let result = try await Task.detached(priority: .userInitiated) {
                    try await ArchiveComparison.compare(archive: mine, with: other)
                }.value
                comparison = .finished(name: name, result: result)
            } catch is CancellationError {
                comparison = nil
            } catch {
                comparison = nil
                alert = BrowserAlert(title: "The comparison couldn’t be made", verbatim: error.localizedDescription)
            }
            comparisonTask = nil
        }
    }

    func endComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        comparison = nil
    }

    /// Puts the differences on the pasteboard as text, one per line.
    func copyComparison() {
        guard case .finished(_, let result)? = comparison else { return }
        let marks: [ArchiveComparison.Change: String] = [.added: "+", .removed: "-", .changed: "~"]
        let text = result.items.map { "\(marks[$0.change] ?? "?") \($0.path)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Thumbnails

    static let showsThumbnailsKey = "ShowsImageThumbnails"
    /// Images larger than this are not decompressed for a thumbnail.
    static let thumbnailSizeLimit: UInt64 = 16 << 20

    /// A thumbnail for an image item, made when its row is first shown
    /// (HLD §20, Phase 4). The image is decompressed into the preview
    /// cache, which the inspector shares and which is deleted on close.
    func thumbnail(for node: ArchiveNode) async -> NSImage? {
        guard UserDefaults.standard.object(forKey: Self.showsThumbnailsKey) as? Bool ?? true,
              let archive, let entry = node.entry, entry.type == .file, entry.isReadable,
              entry.uncompressedSize <= Self.thumbnailSizeLimit,
              UTType(filenameExtension: entry.pathExtension)?.conforms(to: .image) == true
        else { return nil }
        if let cached = thumbnails[entry.id] { return cached }
        let previews = self.previews
        await ThumbnailGate.shared.acquire()
        var image: NSImage?
        if !Task.isCancelled, let url = try? await previews.file(for: entry, in: archive) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 36, height: 36), scale: 2, representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        await ThumbnailGate.shared.release()
        guard !Task.isCancelled, let image else { return nil }
        if thumbnails.count > 800 { thumbnails.removeAll() }
        thumbnails[entry.id] = image
        return image
    }

    // MARK: Safety report, checksums

    private func clearInsight() {
        safetyReport = nil
        safetySeverities = [:]
        isSafetyReportPresented = false
        isSafetyBannerDismissed = false
        sha256Values = [:]
        sha256InProgress = nil
        checksumExport = nil
        thumbnails = [:]
    }

    /// Analyses the directory for anything suspicious, without blocking the
    /// window; the banner appears when it is done.
    private func analyzeSafety(of archive: any ArchiveProvider) {
        safetyTask?.cancel()
        clearInsight()
        checksumTask?.cancel()
        safetyTask = Task {
            let report = await archive.safetyReport()
            guard !Task.isCancelled else { return }
            safetyReport = report
            safetySeverities = report.severityByEntryID
        }
    }

    func dismissSafetyBanner() {
        isSafetyBannerDismissed = true
    }

    /// Shows an entry in the folder that holds it, selected.
    func reveal(_ entryID: ArchiveEntry.ID) {
        guard let node = nodesByID[entryID], let parent = parentByID[entryID] else { return }
        viewMode = .list
        currentFolderID = parent.id
        selection = [node.id]
    }

    /// A click in the treemap: selects the item, showing the folder that
    /// holds it first when it is below the one being shown. The item is then
    /// a row in the list view too.
    func selectInTreemap(_ node: ArchiveNode) {
        if let parent = parentByID[node.id], parent.id != currentFolderID {
            // Selecting changes the folder's rows, which clears the selection,
            // so the folder is not changed: select the ancestor in this folder.
            var ancestor = node
            while let up = parentByID[ancestor.id], up.id != currentFolderID { ancestor = up }
            selection = [ancestor.id]
        } else {
            selection = [node.id]
        }
    }

    /// Computes the SHA-256 of one item by streaming it, when asked.
    func calculateSHA256(of node: ArchiveNode) {
        guard let archive, let entry = node.entry, entry.type == .file, entry.isReadable,
              sha256InProgress == nil, sha256Values[entry.id] == nil else { return }
        if entry.needsPassword && !isUnlocked {
            requestPassword(for: node) { [weak self] in self?.calculateSHA256(of: node) }
            return
        }
        sha256InProgress = entry.id
        checksumTask = Task {
            defer {
                sha256InProgress = nil
                checksumTask = nil
            }
            do {
                sha256Values[entry.id] = try await archive.sha256(of: entry)
            } catch is CancellationError {
                return
            } catch {
                alert = BrowserAlert(title: "“\(entry.name)” couldn’t be checked", verbatim: error.localizedDescription)
            }
        }
    }

    /// The items a command acts on: the selection, or the folder being
    /// shown when nothing is selected.
    private var commandNodes: [ArchiveNode] {
        guard let folder = currentFolder else { return [] }
        return outermost(selectedNodes.isEmpty ? folder.children : selectedNodes)
    }

    var canExportChecksums: Bool { hasArchive && checksumExport == nil && !isUpdating }

    /// Writes a `shasum -a 256 -c` compatible list for the selection (or
    /// the folder being shown) to a file the user chooses.
    func exportChecksums() {
        guard let archive, let tree, let archiveURL, canExportChecksums else { return }
        let entries = commandNodes.flatMap { tree.entries(under: $0) }.filter { $0.type == .file }
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        if !isUnlocked, entries.contains(where: \.needsPassword) {
            requestPassword { [weak self] in self?.exportChecksums() }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = archiveURL.deletingPathExtension().lastPathComponent + ".sha256"
        panel.message = String(localized: "Choose where to save the checksum list.")
        panel.directoryURL = archiveURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        checksumExport = ChecksumExportStatus(total: entries.count)
        let reporter = ProgressReporter { [weak self] (done: Int) in
            self?.checksumExport?.completed = done
        }
        let total = entries.count
        checksumTask = Task {
            defer {
                checksumExport = nil
                checksumTask = nil
            }
            do {
                let (text, skipped) = try await archive.checksumList(for: entries) { reporter.report($0, isFinal: $0 == total) }
                try text.write(to: destination, atomically: true, encoding: .utf8)
                if !skipped.isEmpty {
                    let names = skipped.prefix(10).map(\.path).joined(separator: "\n")
                    alert = BrowserAlert(
                        title: "\(skipped.count) items are not in the list",
                        verbatim: String(localized: "Encrypted, unsupported or damaged items have no checksum:") + "\n" + names
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                alert = BrowserAlert(title: "The checksum list couldn’t be saved", verbatim: error.localizedDescription)
            }
        }
    }

    func cancelChecksums() {
        checksumTask?.cancel()
    }

    // MARK: Verification

    /// Verify Archive (HLD §18.1): decompresses every item and checks it,
    /// writing nothing to disk.
    func verifyArchive() {
        guard let archive, !isVerifying else { return }
        let total = entries.count
        verification = .running(checked: 0, total: total)
        let reporter = ProgressReporter { [weak self] (checked: Int) in
            guard let self, case .running = self.verification else { return }
            self.verification = .running(checked: checked, total: total)
        }
        verificationTask = Task {
            do {
                let report = try await archive.verify { reporter.report($0, isFinal: $0 == total) }
                verification = .finished(report)
            } catch {
                // Only cancellation stops a verification.
                verification = nil
            }
            verificationTask = nil
        }
    }

    /// Stops a running verification, or dismisses its report.
    func endVerification() {
        verificationTask?.cancel()
        verificationTask = nil
        verification = nil
    }

    private func finishExtraction(_ result: ExtractionResult, request: PendingExtraction, extractor: ArchiveExtractor) {
        // Reveal the top-level items written, which may have been renamed by
        // Keep Both.
        let defaults = UserDefaults.standard
        let root = extractor.destination.standardizedFileURL.path
        let topLevel = result.extracted.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path == root
        }
        if defaults.object(forKey: Self.revealAfterExtractionKey) as? Bool ?? true {
            if !topLevel.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(topLevel)
            } else if !result.extracted.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([extractor.destination])
            }
        }
        AccessibilityNotification.Announcement(
            String(localized: "Extracted \(result.extracted.count) items")
        ).post()

        // Only after everything was written: a partial extraction must
        // leave the archive where it is.
        if request.isWholeArchive, defaults.bool(forKey: Self.trashAfterExtractionKey),
           result.failures.isEmpty, result.skipped.isEmpty, !result.extracted.isEmpty,
           let archiveURL {
            do {
                try FileManager.default.trashItem(at: archiveURL, resultingItemURL: nil)
            } catch {
                alert = BrowserAlert(
                    title: "“\(archiveURL.lastPathComponent)” couldn’t be moved to the Trash",
                    verbatim: error.localizedDescription
                )
            }
        }

        guard !result.failures.isEmpty else { return }
        let shown = result.failures.prefix(10).map { $0.error.localizedDescription }
        var message = shown.joined(separator: "\n")
        if result.failures.count > shown.count {
            message += "\n" + String(localized: "…and \(result.failures.count - shown.count) more.")
        }
        let extracted = result.extracted.count
        alert = BrowserAlert(
            title: extracted == 0
                ? "No items could be extracted"
                : "\(result.failures.count) of \(result.failures.count + extracted) items couldn’t be extracted",
            verbatim: message
        )
    }

    private func chooseDestination(itemCount: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Extract")
        panel.message = itemCount == 1
            ? String(localized: "Choose where to extract the item.")
            : String(localized: "Choose where to extract the items.")
        panel.directoryURL = archiveURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func makeUniqueFolder(named name: String, in parent: URL, quarantine: Data?) throws -> URL {
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
}

private struct LoadedArchive: Sendable {
    let archive: any ArchiveProvider
    let entries: [ArchiveEntry]
    let warnings: [String]
    let detectedEncoding: FilenameEncoding?
    let browsing: BrowsingData
}

/// What the window needs to browse an archive's entries.
private struct BrowsingData: Sendable {
    let tree: ArchiveTree
    let nodesByID: [ArchiveNode.ID: ArchiveNode]
    let parentByID: [ArchiveNode.ID: ArchiveNode]
    let searchIndex: ArchiveSearchIndex
}

/// Forwards progress, which arrives off the main actor as often as once per
/// decompressed chunk, to the UI at most ten times a second.
private final class ProgressReporter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    private let update: @MainActor (Value) -> Void

    init(update: @escaping @MainActor (Value) -> Void) {
        self.update = update
    }

    /// `isFinal` reports always get through, so the UI ends up complete.
    func report(_ value: Value, isFinal: Bool) {
        let now = Date()
        lock.lock()
        let isDue = now.timeIntervalSince(lastReport) >= 0.1 || isFinal
        if isDue { lastReport = now }
        lock.unlock()
        guard isDue else { return }
        Task { @MainActor in self.update(value) }
    }
}

/// Watches the archive file for changes made by other applications
/// (HLD §18.3). Callbacks arrive on the main queue.
final class ArchiveFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private(set) var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    var onChange: (@MainActor (ExternalChange) -> Void)?
    var onMove: (@MainActor (URL) -> Void)?

    init(url: URL) {
        presentedItemURL = url
    }

    func presentedItemDidChange() {
        MainActor.assumeIsolated { onChange?(.modified) }
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        // Moving to the Trash is how Finder deletes.
        let isInTrash = newURL.pathComponents.contains(".Trash")
        MainActor.assumeIsolated {
            if isInTrash {
                onChange?(.deleted)
            } else {
                onMove?(newURL)
            }
        }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        MainActor.assumeIsolated { onChange?(.deleted) }
        completionHandler(nil)
    }
}

/// File kinds and icons from the system's type information (HLD §18.3).
@MainActor
enum FileTypes {
    private static var kinds: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func kind(of node: ArchiveNode) -> String {
        if node.isDirectory { return String(localized: "Folder") }
        if node.entry?.type == .symlink { return String(localized: "Alias") }
        let ext = node.entry?.pathExtension ?? ""
        if let cached = kinds[ext] { return cached }
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? String(localized: "Document")
        kinds[ext] = kind
        return kind
    }

    static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : node.entry?.pathExtension ?? ""
        if let cached = icons[key] { return cached }
        let type: UTType = node.isDirectory
            ? .folder
            : UTType(filenameExtension: key) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icons[key] = icon
        return icon
    }
}
