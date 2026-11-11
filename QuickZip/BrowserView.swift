import SwiftUI
import ArchiveKit
import QuickLook

/// The main browser window (HLD §8): folders in the sidebar, the current
/// folder's contents in a sortable list, and an inspector with an inline
/// preview of the selected file.
/// The sheets a browser window can show. A modifier of its own so that the
/// window's body stays small enough to type-check.
private struct BrowserSheets: ViewModifier {
    @Bindable var model: ArchiveBrowserModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.verification != nil }, set: { if !$0 { model.endVerification() } })) {
                VerificationSheet(model: model)
            }
            .sheet(isPresented: $model.isSafetyReportPresented) {
                SafetyReportSheet(model: model)
            }
            .sheet(isPresented: $model.isPasswordPromptPresented) {
                PasswordSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.comparison != nil }, set: { if !$0 { model.endComparison() } })) {
                ComparisonSheet(model: model)
            }
    }
}

struct BrowserView: View {
    @State private var model = ArchiveBrowserModel()
    @AppStorage(WindowTabbing.opensInTabsKey) private var opensInTabs = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            // The inspector is a plain column of fixed width beside the file
            // list, not SwiftUI's `.inspector`. That nests a second split
            // view inside this one, and the two renegotiate their minimum
            // sizes until AppKit kills the app for running too many Update
            // Constraints passes: on macOS 27, at launch.
            HStack(spacing: 0) {
                FileListView(model: model)
                if model.isInspectorPresented {
                    Divider()
                    InspectorView(model: model)
                        .frame(width: 320)
                }
            }
            // The same minimum size whatever the column shows. A minimum
            // height that followed the width, as wrapped text and banners
            // do, would change each time the split view laid the column
            // out, and so make it lay the column out again.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: searchPrompt)
        .navigationTitle(title)
        .frame(minWidth: 760, minHeight: 420)
        .quickLookPreview($model.quickLookURL)
        .dropDestination(for: URL.self) { urls, _ in
            // Items dragged out of this window and back are not added again.
            guard !model.isOwnExport(urls) else { return false }
            // With an archive open, dropped items are added to the folder
            // being shown, as in Finder; otherwise a dropped ZIP is opened.
            if model.hasArchive {
                guard model.canEdit, !urls.isEmpty else { return false }
                model.add(urls)
                return true
            }
            guard let url = urls.first(where: ArchiveTypes.isOpenable) ?? urls.first else {
                return false
            }
            model.open(url)
            return true
        }
        .confirmationDialog(
            "Some items already exist",
            isPresented: Binding(get: { model.pendingAddition != nil }, set: { _ in }),
            presenting: model.pendingAddition
        ) { _ in
            Button("Keep Both") { model.resolvePendingAddition(with: .keepBoth) }
            Button("Replace", role: .destructive) { model.resolvePendingAddition(with: .replace) }
            Button("Skip") { model.resolvePendingAddition(with: .skip) }
            Button("Cancel", role: .cancel) { model.resolvePendingAddition(with: nil) }
        } message: { request in
            Text(additionConflictMessage(for: request))
        }
        .alert(
            model.pendingDeletion?.title ?? "",
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .confirmationDialog(
            "Some items already exist",
            isPresented: Binding(get: { model.pendingExtraction != nil }, set: { _ in }),
            presenting: model.pendingExtraction
        ) { _ in
            Button("Keep Both") { model.resolvePendingExtraction(with: .keepBoth) }
            Button("Replace", role: .destructive) { model.resolvePendingExtraction(with: .replace) }
            Button("Skip") { model.resolvePendingExtraction(with: .skip) }
            Button("Cancel", role: .cancel) { model.resolvePendingExtraction(with: nil) }
        } message: { request in
            Text(conflictMessage(for: request))
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .modifier(BrowserSheets(model: model))
        // Archives opened from Finder (HLD §18.3) go to a window that has
        // none open yet; otherwise SwiftUI opens a new window for them.
        .onOpenURL { url in
            model.open(url)
        }
        .handlesExternalEvents(
            preferring: model.hasArchive || model.isOpening ? [] : ["*"],
            allowing: model.hasArchive || model.isOpening ? [] : ["*"]
        )
        .background(WindowTabbing(opensInTabs: opensInTabs, model: model))
        .focusedSceneValue(\.browser, model)
        .onDisappear { model.close() }
    }

    private var searchPrompt: String {
        if let folder = model.currentFolder, !folder.path.isEmpty {
            return String(localized: "Search “\(folder.name)”")
        }
        return String(localized: "Search")
    }

    /// The current folder's name; the folders above it are the breadcrumbs
    /// that sit just before the title.
    private var title: String {
        if let folder = model.currentFolder, !folder.name.isEmpty { return folder.name }
        return model.archiveURL?.lastPathComponent ?? "QuickZip"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goToEnclosingFolder()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.left")
            }
            .help("Show the enclosing folder")
            .disabled(!model.canGoToEnclosingFolder)
        }
        if !model.currentFolderAncestors.isEmpty {
            ToolbarItem(placement: .navigation) {
                Breadcrumbs(model: model)
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("Size Map", systemImage: "square.grid.2x2").tag(BrowserViewMode.treemap)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the items as a list or as a map of their sizes")
            .disabled(!model.hasArchive)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open an archive")

            Button {
                model.presentAddPanel()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add files to the folder being shown")
            .disabled(!model.canEdit)

            Button {
                model.openInDefaultApplication()
            } label: {
                Label("Open in App", systemImage: "arrow.up.forward.app")
            }
            .help("Open the selected files in their default applications")
            .disabled(model.openableNodes.isEmpty)

            Button {
                model.quickLook()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .help("Preview the selected file")
            .disabled(model.selectedNode.map { $0.isDirectory } ?? true)

            ShareLink(items: model.selectedTransferItems) { item in
                SharePreview(item.name)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share the selected items")
            .disabled(model.selectedTransferItems.isEmpty)

            Button {
                model.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.extractSelection()
            } label: {
                Label("Extract", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Extract the selected items")
            .disabled(!model.canExtract)
        }
    }

    private func additionConflictMessage(for request: PendingAddition) -> String {
        let subject = request.conflictingNames.count == 1
            ? String(localized: "“\(request.conflictingNames[0])” is already in this folder.")
            : String(localized: "\(request.conflictingNames.count) items are already in this folder.")
        let choices = String(localized: "Keep Both adds the new items with new names. Replace deletes the existing items from the archive, including everything in folders.")
        return subject + " " + choices
    }

    private func conflictMessage(for request: PendingExtraction) -> String {
        let folder = request.destination.lastPathComponent
        let subject = request.conflictingNames.count == 1
            ? String(localized: "“\(request.conflictingNames[0])” already exists in “\(folder)”.")
            : String(localized: "\(request.conflictingNames.count) items already exist in “\(folder)”.")
        let choices = String(localized: "Keep Both gives extracted files new names. Replace overwrites existing files. Folders are merged either way.")
        return subject + " " + choices
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var model: ArchiveBrowserModel

    var body: some View {
        List(selection: $model.currentFolderID) {
            if let root = model.tree?.root {
                ArchiveSummaryRow(node: root)
                    .tag(Optional(root.id))
                if !root.directoryChildren.isEmpty {
                    Section("Folders") {
                        OutlineGroup(root.directoryChildren, children: \.sidebarChildren) { node in
                            FolderRow(node: node)
                                .tag(Optional(node.id))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The archive itself, at the top of the sidebar: its name and total size.
private struct ArchiveSummaryRow: View {
    let node: ArchiveNode

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text("\(Int64(clamping: node.totalUncompressedSize), format: .byteCount(style: .file)) uncompressed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct FolderRow: View {
    let node: ArchiveNode

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Int64(clamping: node.totalUncompressedSize), format: .byteCount(style: .file))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        } icon: {
            Image(systemName: "folder")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name), folder, \(Int64(clamping: node.totalUncompressedSize).formatted(.byteCount(style: .file)))")
    }
}

/// The folders above the current one, nearest last. Long paths show only the
/// last two; the sidebar has the rest.
private struct Breadcrumbs: View {
    let model: ArchiveBrowserModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.currentFolderAncestors.suffix(2))) { folder in
                Button(folder.name) {
                    model.currentFolderID = folder.id
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
                .help("Show “\(folder.name)”")
                .accessibilityLabel("Show folder \(folder.name)")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 4)
    }
}

private extension ArchiveNode {
    /// Child folders, or nil for a leaf so the outline shows no disclosure
    /// triangle.
    var sidebarChildren: [ArchiveNode]? {
        let folders = directoryChildren
        return folders.isEmpty ? nil : folders
    }
}

// MARK: - File list

struct FileListView: View {
    @Bindable var model: ArchiveBrowserModel

    var body: some View {
        Group {
            if model.hasArchive {
                if model.viewMode == .treemap {
                    TreemapView(model: model)
                } else {
                    table
                }
            } else if model.isOpening {
                OpeningView(model: model)
            } else if let message = model.openError {
                ContentUnavailableView {
                    Label("Couldn’t Open Archive", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Open Another…") { model.presentOpenPanel() }
                }
            } else {
                DropZone { model.presentOpenPanel() }
            }
        }
        // No minimum width, so the table's columns never push the inspector
        // out of the window (see BrowserView). The table scrolls sideways
        // instead.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let change = model.externalChange, let url = model.archiveURL {
                    ExternalChangeBanner(change: change, archiveName: url.lastPathComponent, model: model)
                }
                if !model.warnings.isEmpty {
                    WarningBanner(warnings: model.warnings)
                }
                if model.lockedItemCount > 0 {
                    PasswordBanner(count: model.lockedItemCount, model: model)
                }
                if let report = model.safetyReport, !report.isEmpty, !model.isSafetyBannerDismissed {
                    SafetyBanner(report: report, model: model)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.hasArchive {
                StatusBar(model: model)
            }
        }
    }

    private var table: some View {
        Table(of: FileRow.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                NameCell(row: row, model: model)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Size", value: \.size) { row in
                Text(Int64(clamping: row.size), format: .byteCount(style: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Saved", value: \.saving) { row in
                Text(row.saving.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(row.saving.formatted(.percent.precision(.fractionLength(0)))) smaller"))
            }
            .width(min: 50, ideal: 64)

            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.modified == .distantPast
                     ? "--"
                     : row.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 170)
        } rows: {
            ForEach(model.rows) { row in
                // Dragging a selected row drags the whole selection; each
                // item is extracted only when it is dropped (HLD §11).
                TableRow(row)
                    .draggable(model.transferItem(for: row.node))
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .accessibilityLabel("Archive contents")
        .overlay {
            if model.rows.isEmpty, model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        // ⌘C promises the selected items to the pasteboard, so they can be
        // pasted into Finder (HLD §18.3).
        .copyable(model.selectedTransferItems)
        .contextMenu(forSelectionType: ArchiveNode.ID.self) { ids in
            if ids.isEmpty {
                Button("Add Files…") { model.presentAddPanel() }
                    .disabled(!model.canEdit)
                Button("Extract All…") { model.extractAll() }
                    .disabled(!model.canExtract)
            } else {
                Button("Open") { model.activate(ids) }
                if ids.count == 1, let node = ids.first.flatMap({ model.node(withID: $0) }), model.isNestedArchive(node) {
                    Button("Open Archive in New Tab") { model.openNestedArchive(node) }
                }
                Button("Quick Look") {
                    model.selection = ids
                    model.quickLook()
                }
                .disabled(ids.count != 1)
                Divider()
                Button("Copy") {
                    model.selection = ids
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                Button("Extract…") {
                    model.selection = ids
                    model.extractSelection()
                }
                .disabled(!model.canExtract)
                Button("Export Checksums…") {
                    model.selection = ids
                    model.exportChecksums()
                }
                .disabled(!model.canExportChecksums)
                Divider()
                Button("Delete…") {
                    model.selection = ids
                    model.requestDeleteSelection()
                }
                .disabled(!model.canEdit)
            }
        } primaryAction: { ids in
            model.activate(ids)
        }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .onDeleteCommand {
            model.requestDeleteSelection()
        }
    }
}

/// An item's icon and name and, for search results, the folder it is in.
private struct ThumbnailKey: Hashable {
    let id: ArchiveNode.ID
    let isUnlocked: Bool
}

private struct NameCell: View {
    let row: FileRow
    let model: ArchiveBrowserModel
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: thumbnail ?? FileTypes.icon(for: row.node))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 2))
                .accessibilityHidden(true)
                // Made lazily, only while the row is on screen.
                .task(id: ThumbnailKey(id: row.node.id, isUnlocked: model.isUnlocked)) {
                    thumbnail = await model.thumbnail(for: row.node)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let location = row.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if let severity = model.safetySeverities[row.node.id] {
                Image(systemName: severity == .blocked ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(severity == .blocked ? Color.red : Color.orange)
                    .help(severity == .blocked ? "Won’t be extracted: see the safety report" : "Be careful with this item: see the safety report")
                    .accessibilityLabel(severity == .blocked ? "Unsafe" : "Be careful")
            }
            if row.node.entry?.isEncrypted == true {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Encrypted")
                    .accessibilityLabel("Encrypted")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// What shows while an archive is read from the start, which for a
/// compressed tar or an Apple Archive can take a while.
private struct OpeningView: View {
    let model: ArchiveBrowserModel

    var body: some View {
        VStack(spacing: 14) {
            if let progress = model.openProgress {
                ProgressView(value: progress)
                    .frame(width: 240)
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
            } else {
                ProgressView()
            }
            Text("Reading “\(model.archiveURL?.lastPathComponent ?? "")”…")
                .foregroundStyle(.secondary)
            Text("This kind of archive has to be read from the start to list it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button("Stop") { model.cancelOpening() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

/// The window with nothing open: one target for a drop or a click.
private struct DropZone: View {
    let open: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric private var tile = 68.0

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.zipper")
                .font(.system(size: tile * 0.47, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Drop an archive here to browse it")
                    .font(.title2.bold())
                Text("Look inside, preview files and pull out only what you need. Nothing is unpacked until you extract it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button("Open Archive…", action: open)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color(nsColor: contrast == .increased ? .labelColor : .tertiaryLabelColor),
                    style: StrokeStyle(lineWidth: contrast == .increased ? 2 : 1.5, dash: [6, 5])
                )
        }
        .padding(24)
    }
}

private struct WarningBanner: View {
    let warnings: [String]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(warnings.joined(separator: "\n"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(contrast == .increased ? 0.3 : 0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(contrast == .increased ? Color(nsColor: .labelColor) : Color.yellow.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Warning: \(warnings.joined(separator: " "))"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Offers to reload an archive another application has changed.
private struct ExternalChangeBanner: View {
    let change: ExternalChange
    let archiveName: String
    let model: ArchiveBrowserModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: change == .deleted ? "trash" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(change == .deleted
                 ? "“\(archiveName)” was moved to the Trash or deleted. Its contents can still be extracted until you close this window."
                 : "“\(archiveName)” was changed by another application.")
                .frame(maxWidth: .infinity, alignment: .leading)
            if change == .modified {
                Button("Reload") { model.reload() }
                    .disabled(model.isUpdating || model.isExtracting)
            }
            Button("Dismiss") { model.dismissExternalChange() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(contrast == .increased ? 0.25 : 0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

private struct StatusBar: View {
    let model: ArchiveBrowserModel

    var body: some View {
        HStack(spacing: 10) {
            if let status = model.updateStatus {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(status)
            } else if let export = model.checksumExport {
                ProgressView(value: Double(export.completed), total: Double(max(export.total, 1)))
                    .frame(width: 160)
                    .accessibilityLabel("Checksum progress")
                Text("Calculating checksums: \(export.completed) of \(export.total)…")
                    .monospacedDigit()
                Button("Stop") { model.cancelChecksums() }
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
            } else if let extraction = model.extraction {
                ProgressView(value: extraction.fractionCompleted)
                    .frame(width: 160)
                    .accessibilityLabel("Extraction progress")
                    .accessibilityValue(extraction.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
                Text("Extracting \(extraction.completedEntries) of \(extraction.totalEntries) items…")
                    .monospacedDigit()
                Button("Stop") { model.cancelExtraction() }
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop extracting (⌘.)")
            } else {
                Text(summary)
            }
            Spacer()
            if let folder = model.currentFolder {
                Text("\(Int64(clamping: folder.totalUncompressedSize), format: .byteCount(style: .file)) uncompressed")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let count = model.rows.count
        let selected = model.selection.count
        if model.isSearching {
            let matches = model.searchMatchCount
            if matches > count {
                return String(localized: "\(matches) matches, first \(count) shown")
            }
            return selected == 0
                ? String(localized: "\(matches) matches")
                : String(localized: "\(selected) of \(matches) selected")
        }
        return selected == 0
            ? String(localized: "\(count) items")
            : String(localized: "\(selected) of \(count) selected")
    }
}

// MARK: - Focused value for menu commands

extension FocusedValues {
    struct BrowserKey: FocusedValueKey {
        typealias Value = ArchiveBrowserModel
    }

    var browser: ArchiveBrowserModel? {
        get { self[BrowserKey.self] }
        set { self[BrowserKey.self] = newValue }
    }
}
