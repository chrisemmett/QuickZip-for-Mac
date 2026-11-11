import AppIntents
import ArchiveKit
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions (HLD §20, Phase 7). Each one goes through
// `ArchiveAutomation`, which uses the same providers, extractor and limits
// as the browser window and the `quickzip` command.

/// Why an action failed, in words Shortcuts can show.
struct AutomationFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }

    init(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private enum IntentSupport {
    /// Where extracted items are left for Shortcuts to move on. Cleared at
    /// launch, so nothing accumulates.
    static let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutsOutput", isDirectory: true)

    static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: outputRoot)
    }

    /// A file URL for the archive handed to an action, with access held for
    /// the duration of `body`.
    static func withArchive<T>(_ file: IntentFile, _ body: (URL) async throws -> T) async throws -> T {
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await body(url)
        }
        // Content with no file behind it: write it out to read it.
        let folder = outputRoot.appendingPathComponent("Input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(file.filename)
        try file.data.write(to: url)
        return try await body(url)
    }

    /// The password given to the action, or else the one saved in the
    /// Keychain for this archive.
    static func options(password: String?, for archive: URL) -> ArchiveAutomation.Options {
        let given = password?.isEmpty == false ? password : nil
        return ArchiveAutomation.Options(password: given ?? PasswordVault.password(for: archive))
    }
}

struct ListArchiveItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Archive Items"
    static let description = IntentDescription(
        "Lists the items in a ZIP, tar or Apple Archive without extracting anything.",
        categoryName: "Archives"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Archive", supportedTypeIdentifiers: ["public.data"])
    var archive: IntentFile

    @Parameter(title: "Only Items Matching", description: "Words match names; a word with / matches paths; *.pdf matches extensions.")
    var query: String?

    @Parameter(
        title: "Password",
        description: "Only for password-protected archives. It is stored in the shortcut as plain text; an archive whose password was saved in the Keychain with “Remember in Keychain” needs none."
    )
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("List items in \(\.$archive)") {
            \.$query
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        do {
            let result = try await IntentSupport.withArchive(archive) { url in
                try await ArchiveAutomation.list(url, matching: query, options: IntentSupport.options(password: password, for: url))
            }
            let paths = result.items.map { $0.type == "directory" ? $0.path + "/" : $0.path }
            return .result(value: paths, dialog: "Found \(paths.count) items.")
        } catch {
            throw AutomationFailure(error)
        }
    }
}

struct ExtractArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Archive"
    static let description = IntentDescription(
        "Extracts all of an archive, or only the items matching a search, and returns what was extracted. Items that would be written outside the destination are refused.",
        categoryName: "Archives"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Archive", supportedTypeIdentifiers: ["public.data"])
    var archive: IntentFile

    @Parameter(title: "Only Items Matching", description: "Words match names; a word with / matches paths; *.pdf matches extensions.")
    var query: String?

    @Parameter(
        title: "Password",
        description: "Only for password-protected archives. It is stored in the shortcut as plain text; an archive whose password was saved in the Keychain with “Remember in Keychain” needs none."
    )
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Extract \(\.$archive)") {
            \.$query
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        do {
            let destination = IntentSupport.outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let result = try await IntentSupport.withArchive(archive) { url in
                try await ArchiveAutomation.extract(
                    url, to: destination, matching: query, conflict: .keepBoth,
                    options: IntentSupport.options(password: password, for: url)
                )
            }
            if !result.failures.isEmpty, result.extracted.isEmpty {
                throw AutomationFailure(ArchiveError.io(result.failures[0].error))
            }
            // The items at the top of what was extracted: folders come with their contents.
            let topLevel = Set(result.extracted.map { $0.split(separator: "/").first.map(String.init) ?? $0 })
            let files = topLevel.sorted().map { name -> IntentFile in
                let url = destination.appendingPathComponent(name)
                return IntentFile(fileURL: url, filename: name, type: nil)
            }
            let dialog: IntentDialog = result.failures.isEmpty
                ? "Extracted \(result.extracted.count) items."
                : "Extracted \(result.extracted.count) items; \(result.failures.count) could not be extracted."
            return .result(value: files, dialog: dialog)
        } catch let error as AutomationFailure {
            throw error
        } catch {
            throw AutomationFailure(error)
        }
    }
}

struct VerifyArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Verify Archive"
    static let description = IntentDescription(
        "Checks every item in an archive against its stored size and checksum without writing anything. Returns true if nothing is damaged.",
        categoryName: "Archives"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Archive", supportedTypeIdentifiers: ["public.data"])
    var archive: IntentFile

    @Parameter(
        title: "Password",
        description: "Only for password-protected archives. It is stored in the shortcut as plain text; an archive whose password was saved in the Keychain with “Remember in Keychain” needs none."
    )
    var password: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Verify \(\.$archive)") {
            \.$password
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        do {
            let result = try await IntentSupport.withArchive(archive) { url in
                try await ArchiveAutomation.verify(url, options: IntentSupport.options(password: password, for: url))
            }
            let dialog: IntentDialog = result.intact
                ? "Nothing is damaged: \(result.verified) items checked."
                : "\(result.damaged.count) items are damaged."
            return .result(value: result.intact, dialog: dialog)
        } catch {
            throw AutomationFailure(error)
        }
    }
}

struct QuickZipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListArchiveItemsIntent(),
            phrases: ["List items in an archive with \(.applicationName)"],
            shortTitle: "List Archive Items",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: ExtractArchiveIntent(),
            phrases: ["Extract an archive with \(.applicationName)"],
            shortTitle: "Extract Archive",
            systemImageName: "arrow.down.doc"
        )
        AppShortcut(
            intent: VerifyArchiveIntent(),
            phrases: ["Verify an archive with \(.applicationName)"],
            shortTitle: "Verify Archive",
            systemImageName: "checkmark.seal"
        )
    }
}

/// Called at launch from the app.
enum ShortcutsOutput {
    static func removeStaleFiles() { IntentSupport.removeStaleFiles() }
}
