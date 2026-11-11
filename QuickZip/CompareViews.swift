import SwiftUI
import ArchiveKit

/// The result of comparing the open archive with another archive or a
/// folder (HLD §20, Phase 5).
struct ComparisonSheet: View {
    let model: ArchiveBrowserModel
    @State private var filter: ArchiveComparison.Change?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.comparison {
            case .running(let name)?:
                Text("Comparing with “\(name)”…").font(.headline)
                ProgressView()
                HStack {
                    Spacer()
                    Button("Stop", role: .cancel) { model.endComparison() }.keyboardShortcut(.cancelAction)
                }
            case .finished(let name, let result)?:
                finished(name: name, result: result)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func finished(name: String, result: ArchiveComparison) -> some View {
        Text("“\(model.archiveURL?.lastPathComponent ?? "")” compared with “\(name)”")
            .font(.headline)
        if result.isIdentical {
            Label("Every item matches.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Picker("Show", selection: $filter) {
                Text("All \(result.items.count)").tag(ArchiveComparison.Change?.none)
                Text("Only in “\(name)” \(result.count(.added))").tag(ArchiveComparison.Change?.some(.added))
                Text("Only here \(result.count(.removed))").tag(ArchiveComparison.Change?.some(.removed))
                Text("Different \(result.count(.changed))").tag(ArchiveComparison.Change?.some(.changed))
            }
            .pickerStyle(.segmented)
            List(result.items.filter { filter == nil || $0.change == filter }) { item in
                HStack(spacing: 8) {
                    Image(systemName: symbol(item.change))
                        .foregroundStyle(color(item.change))
                        .frame(width: 18)
                        .accessibilityLabel(label(item.change))
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(sizes(item))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(height: 280)
        }
        Text(footer(result))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Copy List") { model.copyComparison() }
                .disabled(result.isIdentical)
            Spacer()
            Button("Done") { model.endComparison() }.keyboardShortcut(.defaultAction)
        }
    }

    private func footer(_ result: ArchiveComparison) -> String {
        var parts = [String(localized: "\(result.unchangedCount) items are the same.")]
        if result.unverifiedCount > 0 {
            parts.append(String(localized: "\(result.unverifiedCount) have the same size but no checksum to confirm it."))
        }
        if result.skippedLinkCount > 0 {
            parts.append(String(localized: "\(result.skippedLinkCount) links in the folder were not compared."))
        }
        if let prefix = result.archivePrefix ?? result.otherPrefix {
            parts.append(String(localized: "Compared without the top-level folder “\(prefix)”."))
        }
        return parts.joined(separator: " ")
    }

    private func sizes(_ item: ArchiveComparison.Item) -> String {
        func format(_ bytes: UInt64?) -> String {
            bytes.map { Int64(clamping: $0).formatted(.byteCount(style: .file)) } ?? "–"
        }
        return item.change == .changed ? "\(format(item.archiveSize)) → \(format(item.otherSize))" : format(item.archiveSize ?? item.otherSize)
    }

    private func symbol(_ change: ArchiveComparison.Change) -> String {
        switch change {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .changed: return "pencil.circle.fill"
        }
    }

    private func color(_ change: ArchiveComparison.Change) -> Color {
        switch change {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    private func label(_ change: ArchiveComparison.Change) -> LocalizedStringKey {
        switch change {
        case .added: return "Only in the other"
        case .removed: return "Only in this archive"
        case .changed: return "Different"
        }
    }
}
