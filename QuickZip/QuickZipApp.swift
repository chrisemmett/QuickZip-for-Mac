import SwiftUI
import ArchiveKit

@main
struct QuickZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Preview and export files left behind by a previous run that did
        // not quit cleanly, and copies opened in other applications.
        PreviewCache.removeStaleFiles()
        ArchiveSpool.removeStaleFiles()
        ShortcutsOutput.removeStaleFiles()
        ItemExporter.removeStaleFiles()
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
        }
        .commands {
            ArchiveCommands()
            ViewCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Menu commands acting on the focused browser window.
struct ArchiveCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @ObservedObject private var recents = RecentArchives.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("t")
            Button("Open…") { browser?.presentOpenPanel() }
                .keyboardShortcut("o")
                .disabled(browser == nil)
            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { recents.open(url, in: browser) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
            }
            .disabled(recents.urls.isEmpty)
        }

        CommandMenu("Archive") {
            Button("Open Item") { browser?.openInDefaultApplication() }
                .keyboardShortcut(.downArrow)
                .disabled(browser?.openableNodes.isEmpty ?? true)
            Button("Quick Look") { browser?.quickLook() }
                .keyboardShortcut("y")
                .disabled(browser?.selectedNode.map { $0.isDirectory } ?? true)
            Divider()
            Button("Add Files…") { browser?.presentAddPanel() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!(browser?.canEdit ?? false))
            Button("Delete…") { browser?.requestDeleteSelection() }
                .keyboardShortcut(.delete)
                .disabled(!(browser?.canDeleteSelection ?? false))
            Divider()
            Button("Extract…") { browser?.extractSelection() }
                .keyboardShortcut("e")
                .disabled(!(browser?.canExtract ?? false))
            Button("Extract All…") { browser?.extractAll() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(browser?.canExtract ?? false))
            Divider()
            Button("Verify Archive") { browser?.verifyArchive() }
                .disabled(!(browser?.hasArchive ?? false) || (browser?.isVerifying ?? false))
            Button("Safety Report…") { browser?.isSafetyReportPresented = true }
                .disabled(browser?.safetyReport == nil)
            Button("Enter Password…") { browser?.requestPassword() }
                .disabled(!(browser?.hasEncryptedItems ?? false))
            Button("Forget Saved Password") { browser?.forgetSavedPassword() }
                .disabled(!(browser?.hasSavedPassword ?? false))
            Button("Compare With…") { browser?.presentComparePanel() }
                .disabled(!(browser?.hasArchive ?? false))
            Button("Export Checksums…") { browser?.exportChecksums() }
                .disabled(!(browser?.canExportChecksums ?? false))
            Button("Reload") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(!(browser?.hasArchive ?? false))
        }

        CommandMenu("Go") {
            Button("Enclosing Folder") { browser?.goToEnclosingFolder() }
                .keyboardShortcut(.upArrow)
                .disabled(!(browser?.canGoToEnclosingFolder ?? false))
        }
    }
}

/// View menu: name encoding and `__MACOSX` visibility (HLD §18.1, §18.2),
/// and the inspector.
struct ViewCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("as List") { browser?.viewMode = .list }
                .keyboardShortcut("1")
                .disabled(browser?.hasArchive != true)
            Button("as Size Map") { browser?.viewMode = .treemap }
                .keyboardShortcut("2")
                .disabled(browser?.hasArchive != true)
            Divider()
            Toggle("Show macOS Metadata Files", isOn: Binding(
                get: { browser?.showsMacOSMetadata ?? false },
                set: { browser?.setShowsMacOSMetadata($0) }
            ))
            .disabled(browser == nil)

            Menu("Text Encoding") {
                Picker("Text Encoding", selection: Binding(
                    get: { browser?.filenameEncoding ?? .automatic },
                    set: { browser?.setFilenameEncoding($0) }
                )) {
                    ForEach(TextEncodingOption.all) { option in
                        Text(option.encoding == .automatic ? automaticTitle : option.name)
                            .tag(option.encoding)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(browser == nil)
            Divider()
        }

        // SwiftUI's InspectorCommands only work with `.inspector`, which the
        // browser window doesn't use (see BrowserView).
        CommandGroup(after: .sidebar) {
            Button(browser?.isInspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                browser?.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(browser == nil)
        }
    }

    /// "Automatic", plus what it settled on for the archive shown.
    private var automaticTitle: String {
        guard let detected = browser?.detectedFilenameEncoding,
              let option = TextEncodingOption.all.first(where: { $0.encoding == detected })
        else { return String(localized: "Automatic") }
        return String(localized: "Automatic (\(option.name))")
    }
}

/// An encoding offered in View → Text Encoding. Names that are not marked
/// as UTF-8 are decoded with it; names that are marked are unaffected.
struct TextEncodingOption: Identifiable {
    let name: String
    let encoding: FilenameEncoding

    var id: String { name }

    static let all: [TextEncodingOption] = {
        var options = [
            TextEncodingOption(name: String(localized: "Automatic"), encoding: .automatic),
            TextEncodingOption(name: String(localized: "Unicode (UTF-8)"), encoding: .encoding(.utf8)),
            TextEncodingOption(name: String(localized: "Western (DOS Latin US)"), encoding: .cp437),
            TextEncodingOption(name: String(localized: "Western (Windows Latin 1)"), encoding: .encoding(.windowsCP1252)),
            TextEncodingOption(name: String(localized: "Central European (Windows Latin 2)"), encoding: .encoding(.windowsCP1250)),
            TextEncodingOption(name: String(localized: "Cyrillic (DOS)"), encoding: .cp866),
            TextEncodingOption(name: String(localized: "Cyrillic (Windows)"), encoding: .encoding(.windowsCP1251)),
            TextEncodingOption(name: String(localized: "Greek (Windows)"), encoding: .encoding(.windowsCP1253)),
            TextEncodingOption(name: String(localized: "Turkish (Windows)"), encoding: .encoding(.windowsCP1254)),
            TextEncodingOption(name: String(localized: "Japanese (Shift JIS)"), encoding: .encoding(.shiftJIS)),
        ]
        if let gb18030 = FilenameEncoding.gb18030 {
            options.append(TextEncodingOption(name: String(localized: "Chinese Simplified (GBK)"), encoding: gb18030))
        }
        options.append(TextEncodingOption(name: String(localized: "Chinese Traditional (Big 5)"), encoding: coreFoundation(.big5)))
        options.append(TextEncodingOption(name: String(localized: "Korean (Windows)"), encoding: coreFoundation(.dosKorean)))
        return options
    }()

    private static func coreFoundation(_ encoding: CFStringEncodings) -> FilenameEncoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return .encoding(String.Encoding(rawValue: raw))
    }
}
