import SwiftUI
import ArchiveKit

/// Verify Archive (HLD §18.1): progress while every item is decompressed
/// and checked, then what was found.
struct VerificationSheet: View {
    let model: ArchiveBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.verification {
            case .running(let checked, let total)?:
                running(checked: checked, total: total)
            case .finished(let report)?:
                finished(report)
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var archiveName: String {
        model.archiveURL?.lastPathComponent ?? String(localized: "the archive")
    }

    @ViewBuilder
    private func running(checked: Int, total: Int) -> some View {
        Text("Verifying “\(archiveName)”…")
            .font(.headline)
        ProgressView(value: Double(checked), total: Double(max(total, 1)))
            .accessibilityLabel("Verification progress")
            .accessibilityValue("\(checked) of \(total) items")
        Text("\(checked.formatted()) of \(total.formatted()) items checked")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Stop", role: .cancel) { model.endVerification() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func finished(_ report: VerificationReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: report.isIntact ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 28))
                .foregroundStyle(report.isIntact ? Color.green : Color.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.isIntact ? "“\(archiveName)” is intact" : "“\(archiveName)” is damaged")
                    .font(.headline)
                Text(summary(report))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !report.failures.isEmpty || !report.unverifiable.isEmpty {
            List {
                if !report.failures.isEmpty {
                    Section("Damaged") {
                        ForEach(report.failures, id: \.entry.id) { failure in
                            ProblemRow(path: failure.entry.path, reason: failure.error.localizedDescription)
                        }
                    }
                }
                if !report.unverifiable.isEmpty {
                    Section("Not Checked") {
                        ForEach(report.unverifiable) { entry in
                            ProblemRow(path: entry.path, reason: Self.reasonUnverifiable(entry))
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        HStack {
            Spacer()
            Button("Done") { model.endVerification() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ report: VerificationReport) -> String {
        var parts = [String(localized: "\(report.verifiedCount) files decompressed with the expected size and checksum.")]
        if !report.failures.isEmpty {
            parts.append(String(localized: "\(report.failures.count) items are damaged."))
        }
        if !report.unverifiable.isEmpty {
            parts.append(String(localized: "\(report.unverifiable.count) items couldn’t be checked."))
        }
        return parts.joined(separator: " ")
    }

    private static func reasonUnverifiable(_ entry: ArchiveEntry) -> String {
        entry.isEncrypted
            ? String(localized: "Needs a password")
            : String(localized: "Compressed with \(entry.compressionMethod.description), which is not supported")
    }
}

private struct ProblemRow: View {
    let path: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
