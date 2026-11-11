import Foundation
import ArchiveKit
import CoreTransferable
import UniformTypeIdentifiers

/// Writes archive items to temporary files on demand: for drags and copies
/// to Finder (HLD §11, §18.3), and for opening an item in its default
/// application.
///
/// Items are written through `ArchiveExtractor`, so the same path checks,
/// quarantine propagation and `__MACOSX` merging apply as to an explicit
/// extraction (HLD §13).
actor ItemExporter {
    /// Parent of every exporter's files, cleared at launch in case a previous
    /// run ended without cleaning up.
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Exports", isDirectory: true)

    private let archive: any ArchiveProvider
    private let directory: URL

    /// - Parameter purpose: names the folder the files are written to, so
    ///   that files with different lifetimes can be removed separately.
    init(archive: any ArchiveProvider, purpose: String) {
        self.archive = archive
        self.directory = Self.rootDirectory
            .appendingPathComponent(purpose, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Writes `item` to a new temporary folder and returns its URL. Items in
    /// a folder that could not be written are left out; the call only fails
    /// if the item itself could not be.
    func export(_ item: ArchiveItemTransfer) async throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let extractor = try ArchiveExtractor(destination: folder, options: ExtractionOptions(conflictPolicy: .keepBoth))
            let result = try await extractor.extract(item.entries, from: archive, removingPrefix: item.prefix)
            let url = extractor.destination.appendingPathComponent(item.name, isDirectory: item.isDirectory)
            // Without following a link, whose target may not be included.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
                throw result.failures.first?.error
                    ?? ArchiveError.io("“\(item.name)” could not be extracted.")
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Deletes every file this exporter has written.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

/// An archive item dragged or copied out of the window. Nothing is
/// extracted when the drag starts or the item is copied: the receiver is
/// promised a file, and the item is extracted only when it asks for it.
struct ArchiveItemTransfer: Transferable, Sendable {
    let name: String
    let isDirectory: Bool
    /// The item's entries and, for a folder, everything below it.
    let entries: [ArchiveEntry]
    /// The path of the item's parent, removed from every entry's path.
    let prefix: String
    /// Nil only while no archive is open, when there is nothing to drag.
    let exporter: ItemExporter?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { item in
            SentTransferredFile(try await item.export())
        }
        .exportingCondition { $0.isDirectory }
        .suggestedFileName { $0.name }

        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await item.export())
        }
        .exportingCondition { !$0.isDirectory }
        .suggestedFileName { $0.name }
    }

    private func export() async throws -> URL {
        guard let exporter else { throw CocoaError(.fileNoSuchFile) }
        return try await exporter.export(self)
    }
}
