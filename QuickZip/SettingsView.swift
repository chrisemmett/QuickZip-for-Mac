import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// QuickZip → Settings: making QuickZip the default app for ZIP archives
/// (HLD §18.3). QuickZip registers as a viewer at a lower rank than Archive
/// Utility, so Finder keeps opening ZIPs as before until the user asks.
struct SettingsView: View {
    @AppStorage(ArchiveBrowserModel.revealAfterExtractionKey) private var revealAfterExtraction = true
    @AppStorage(ArchiveBrowserModel.trashAfterExtractionKey) private var trashAfterExtraction = false
    @AppStorage(ArchiveBrowserModel.showsThumbnailsKey) private var showsThumbnails = true
    @AppStorage(WindowTabbing.opensInTabsKey) private var opensInTabs = false
    @State private var isDefault = SettingsView.isDefaultForZIP
    @State private var error: String?
    @State private var toolState = CommandLineTool.state()
    @State private var toolMessage: String?

    var body: some View {
        Form {
            LabeledContent("ZIP archives:") {
                VStack(alignment: .leading, spacing: 6) {
                    if isDefault {
                        Label("QuickZip opens ZIP archives from Finder.", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("Another application opens ZIP archives from Finder.")
                        Button("Make QuickZip the Default") { makeDefault() }
                    }
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Text("You can always open a ZIP with QuickZip from Finder’s Open With menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Windows:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Open each archive in a new tab", isOn: $opensInTabs)
                    Toggle("Show thumbnails for images", isOn: $showsThumbnails)
                    Text("Thumbnails are made by decompressing each image as its row appears. Images over 16 MB are skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Command line:") {
                VStack(alignment: .leading, spacing: 6) {
                    switch toolState {
                    case .installed(let folder):
                        Label("The quickzip command is installed in \(folder).", systemImage: "checkmark.circle.fill")
                        Button("Remove") { removeTool() }
                    case .stale(let folder):
                        Label("The quickzip command in \(folder) points to a copy of QuickZip that has moved.", systemImage: "exclamationmark.triangle.fill")
                        Button("Reinstall…") { installTool() }
                    case .notInstalled:
                        Text("Use QuickZip from Terminal and scripts: quickzip list, extract, verify, test-safety and checksum.")
                        Button("Install Command…") { installTool() }
                            .disabled(!CommandLineTool.isBundled)
                    }
                    Button("Copy Install Command for Terminal") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CommandLineTool.installCommand(), forType: .string)
                        toolMessage = String(localized: "Copied. Paste it into Terminal; it asks for your password because /usr/local/bin needs an administrator.")
                    }
                    .disabled(!CommandLineTool.isBundled)
                    if let toolMessage {
                        Text(toolMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LabeledContent("After extracting:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show the extracted items in Finder", isOn: $revealAfterExtraction)
                    Toggle("Move the archive to the Trash after extracting all of it", isOn: $trashAfterExtraction)
                    Text("Only when every item was extracted. Nothing is moved after extracting a selection, or if any item was skipped or failed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { isDefault = Self.isDefaultForZIP }
    }

    private func installTool() {
        toolMessage = nil
        do {
            if let folder = try CommandLineTool.installInChosenFolder() {
                toolMessage = String(localized: "Installed in \(folder). Open a new Terminal window to use it.")
            }
        } catch {
            toolMessage = String(localized: "The command could not be installed there: \(error.localizedDescription) Use “Copy Install Command for Terminal” instead.")
        }
        toolState = CommandLineTool.state()
    }

    private func removeTool() {
        do {
            try CommandLineTool.uninstall()
            toolMessage = nil
        } catch {
            toolMessage = error.localizedDescription
        }
        toolState = CommandLineTool.state()
    }

    private static var isDefaultForZIP: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: .zip)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefault() {
        error = nil
        // macOS asks the user to confirm the change.
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .zip) { failure in
            Task { @MainActor in
                if let failure {
                    error = failure.localizedDescription
                }
                isDefault = Self.isDefaultForZIP
            }
        }
    }
}
