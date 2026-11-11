import SwiftUI
import ArchiveKit

/// Wording for the engine's safety findings (HLD §20, Phase 3).
extension SafetyFinding {
    var title: String {
        switch kind {
        case .unsafePath: return String(localized: "Would be written outside the destination")
        case .unsafeSymlink: return String(localized: "Link points outside the destination")
        case .exceedsLimits: return String(localized: "Looks like a ZIP bomb")
        case .overlappingData: return String(localized: "Shares data with another item")
        case .applicationBundle: return String(localized: "Application")
        case .executable: return String(localized: "Program or installer")
        case .doubleExtension: return String(localized: "Name hides what it is")
        case .deceptiveCharacters: return String(localized: "Name has hidden or direction-changing characters")
        }
    }

    var explanation: String {
        switch kind {
        case .unsafePath:
            return String(localized: "It will be skipped when extracting.")
        case .unsafeSymlink:
            return detail.map { $0.isEmpty ? String(localized: "Its target is too long to be genuine. It will be skipped.") : String(localized: "It points to “\($0)” and will be skipped when extracting.") }
                ?? String(localized: "It will be skipped when extracting.")
        case .exceedsLimits:
            return detail.map { String(localized: "It was refused because \($0).") } ?? String(localized: "It cannot be opened.")
        case .overlappingData:
            return String(localized: "Items that share data are typical of a ZIP bomb. They cannot be opened.")
        case .applicationBundle:
            return String(localized: "“\(detail ?? name)” can run code when opened.")
        case .executable:
            return String(localized: "Files ending in .\(detail ?? "") can run code when opened.")
        case .doubleExtension:
            return String(localized: "It looks like a .\(detail ?? "") file but is a program.")
        case .deceptiveCharacters:
            return String(localized: "Characters that change how a name reads can make a program look like a document.")
        }
    }

    private var name: String { entry.name }

    var symbol: String {
        severity == .blocked ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
}

/// The banner shown when an archive opens and something in it is suspicious.
struct SafetyBanner: View {
    let report: ArchiveSafetyReport
    let model: ArchiveBrowserModel
    @Environment(\.colorSchemeContrast) private var contrast

    private var blockedCount: Int { Set(report.blocked.map(\.entry.id)).count }
    private var cautionCount: Int { Set(report.cautions.map(\.entry.id)).count }
    private var isBlocking: Bool { blockedCount > 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isBlocking ? "xmark.octagon.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(isBlocking ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if blockedCount > 0 {
                    Text("\(blockedCount) items won’t be extracted because they’re unsafe.")
                }
                if cautionCount > 0 {
                    Text("\(cautionCount) items are programs or have misleading names.")
                        .foregroundStyle(blockedCount > 0 ? .secondary : .primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Review…") { model.isSafetyReportPresented = true }
            Button("Dismiss") { model.dismissSafetyBanner() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (isBlocking ? Color.red : Color.orange).opacity(contrast == .increased ? 0.28 : 0.12),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .labelColor))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

/// Lists every finding, with a way to jump to the item.
struct SafetyReportSheet: View {
    let model: ArchiveBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safety Report")
                .font(.headline)
            if let report = model.safetyReport, !report.isEmpty {
                List {
                    section("Won’t be extracted", report.blocked)
                    section("Be careful with", report.cautions)
                    if report.isTruncated {
                        Text("There are more findings than are listed here.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 320)
            } else {
                ContentUnavailableView("Nothing Suspicious Found", systemImage: "checkmark.shield")
                    .frame(height: 160)
            }
            Text("These checks read only the archive’s directory. Safe-looking items can still contain harmful files, so only open archives from sources you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { model.isSafetyReportPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ findings: [SafetyFinding]) -> some View {
        if !findings.isEmpty {
            Section(title) {
                ForEach(findings) { finding in
                    FindingRow(finding: finding) {
                        model.isSafetyReportPresented = false
                        model.reveal(finding.entry.id)
                    }
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: SafetyFinding
    let show: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.symbol)
                .foregroundStyle(finding.severity == .blocked ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.entry.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(finding.title)
                    .font(.callout)
                Text(finding.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Show", action: show)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Show in list"), show)
    }
}
