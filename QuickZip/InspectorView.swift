import AppKit
import SwiftUI
import ArchiveKit

/// The inspector: an inline preview of the selected file, decompressed to a
/// temporary file without the user extracting anything, and its metadata.
struct InspectorView: View {
    let model: ArchiveBrowserModel

    var body: some View {
        Group {
            if let node = model.selectedNode {
                ItemDetail(model: model, node: node, showsPreview: !node.isDirectory)
            } else if !model.selection.isEmpty {
                ContentUnavailableView("\(model.selection.count) Items Selected", systemImage: "doc.on.doc")
            } else if let folder = model.currentFolder {
                ItemDetail(model: model, node: folder, showsPreview: false)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Preview, name, compression and facts for one item, top to bottom.
private struct ItemDetail: View {
    let model: ArchiveBrowserModel
    let node: ArchiveNode
    let showsPreview: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsPreview {
                    PreviewPane(model: model, node: node)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .card()
                }
                ItemHeader(node: node)
                if let entry = node.entry {
                    ItemSafety(findings: model.safetyReport?.findings(for: entry.id) ?? [])
                }
                if let entry = node.entry, !node.isDirectory, CompressionCard.applies(to: entry) {
                    CompressionCard(entry: entry)
                }
                ItemFacts(model: model, node: node)
            }
            .padding(16)
        }
    }
}

private extension View {
    /// The inspector's raised panels: preview and compression.
    func card() -> some View {
        modifier(CardStyle())
    }
}

private struct CardStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: contrast == .increased ? .labelColor : .separatorColor),
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
    }
}

private struct PreviewPane: View {
    let model: ArchiveBrowserModel
    let node: ArchiveNode

    var body: some View {
        switch model.preview {
        case .ready(let url):
            QuickLookView(url: url)
                .accessibilityLabel("Preview of \(node.name)")
        case .needsPassword:
            VStack(spacing: 10) {
                LargeIcon(node: node)
                Label("Password required", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                Button("Enter Password…") { model.requestPassword(for: node) }
            }
            .padding()
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Preparing preview")
        case .needsConfirmation(let size):
            VStack(spacing: 10) {
                LargeIcon(node: node)
                Text("\(Int64(clamping: size), format: .byteCount(style: .file)) is too large to preview automatically.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Show Preview") { model.updatePreview(force: true) }
            }
            .padding()
        case .unavailable(let reason), .failed(let reason):
            VStack(spacing: 10) {
                LargeIcon(node: node)
                Text("No preview available. \(reason)")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        case .none:
            LargeIcon(node: node)
        }
    }
}

private struct LargeIcon: View {
    let node: ArchiveNode

    var body: some View {
        Image(nsImage: FileTypes.icon(for: node))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemHeader: View {
    let node: ArchiveNode

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileTypes.icon(for: node))
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(FileTypes.kind(of: node)), \(Int64(clamping: node.totalUncompressedSize).formatted(.byteCount(style: .file)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How much smaller the file is in the archive, as a meter.
private struct CompressionCard: View {
    let entry: ArchiveEntry

    /// Only for entries that are actually smaller in the archive; anything
    /// else gets a plain "Compression" row instead.
    static func applies(to entry: ArchiveEntry) -> Bool {
        entry.compressionMethod != .stored
            && entry.uncompressedSize > 0
            && entry.compressedSize < entry.uncompressedSize
    }

    var body: some View {
        let ratio = Double(entry.compressedSize) / Double(entry.uncompressedSize)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\((1 - ratio).formatted(.percent.precision(.fractionLength(0)))) smaller")
                    .fontWeight(.semibold)
                Spacer()
                Text(entry.compressionMethod.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(ratio, 0), 1))
                .accessibilityHidden(true)
            HStack {
                Text("\(Int64(clamping: entry.compressedSize), format: .byteCount(style: .file)) compressed")
                Spacer()
                Text("\(Int64(clamping: entry.uncompressedSize), format: .byteCount(style: .file)) original")
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// What the safety report found about this one item.
private struct ItemSafety: View {
    let findings: [SafetyFinding]

    var body: some View {
        ForEach(findings) { finding in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.symbol)
                    .foregroundStyle(finding.severity == .blocked ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).fontWeight(.semibold)
                    Text(finding.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((finding.severity == .blocked ? Color.red : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ItemFacts: View {
    let model: ArchiveBrowserModel
    let node: ArchiveNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FactRow("Size") {
                Text("\(node.totalUncompressedSize.formatted()) bytes")
                    .monospacedDigit()
            }
            if node.isDirectory {
                FactRow("Contains") {
                    Text("\(node.descendantFileCount) files")
                }
            }
            if let entry = node.entry, !node.isDirectory {
                FactRow("Compressed") {
                    Text("\(entry.compressedSize.formatted()) bytes")
                        .monospacedDigit()
                }
                if !CompressionCard.applies(to: entry) {
                    FactRow("Compression") {
                        Text(entry.compressionMethod.description)
                    }
                }
            }
            if let date = node.entry?.modificationDate {
                FactRow("Modified") {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let entry = node.entry {
                if entry.isEncrypted {
                    FactRow("Encrypted") {
                        Label(entry.encryption.map { encryptionName($0) } ?? String(localized: "Yes"), systemImage: "lock.fill")
                    }
                }
                if let crc = entry.crc32, entry.type == .file {
                    FactRow("CRC-32") {
                        ChecksumValue(text: String(format: "%08X", crc))
                    }
                }
                if entry.type == .file, entry.isReadable {
                    FactRow("SHA-256") {
                        SHA256Value(model: model, node: node, entryID: entry.id)
                    }
                }
                if let permissions = entry.posixPermissions {
                    FactRow("Permissions") {
                        Text(String(permissions & 0o7777, radix: 8))
                            .monospaced()
                    }
                }
                if !node.path.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path")
                            .foregroundStyle(.secondary)
                        Text(node.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

/// A label on the left, its value on the right, and a hairline below.
private struct FactRow<Content: View>: View {
    private let label: LocalizedStringKey
    private let content: Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            content
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

/// The SHA-256, which costs reading the whole item, so it is calculated on
/// request.
private struct SHA256Value: View {
    let model: ArchiveBrowserModel
    let node: ArchiveNode
    let entryID: ArchiveEntry.ID

    var body: some View {
        if let value = model.sha256Values[entryID] {
            ChecksumValue(text: value, label: "SHA-256", wraps: true)
        } else if model.sha256InProgress == entryID {
            ProgressView().controlSize(.small)
                .accessibilityLabel("Calculating SHA-256")
        } else {
            Button("Calculate") { model.calculateSHA256(of: node) }
                .controlSize(.small)
                .disabled(model.sha256InProgress != nil)
        }
    }
}

/// A checksum with a button that copies it.
private struct ChecksumValue: View {
    let text: String
    var label = "CRC-32"
    var wraps = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .monospaced()
                .font(wraps ? .caption : .body)
                .textSelection(.enabled)
                .lineLimit(wraps ? 3 : 1)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(Text("Copy \(label)"))
        }
    }
}

/// How an entry's encryption is described to the user. ZipCrypto is weak
/// (it can be broken with a known part of the file), so it says so.
private func encryptionName(_ encryption: EntryEncryption) -> String {
    switch encryption {
    case .zipCrypto: return String(localized: "ZipCrypto (weak)")
    case .winZipAES(let strength, _): return "AES-\(strength.bits)"
    case .unsupported: return String(localized: "Unsupported")
    }
}
