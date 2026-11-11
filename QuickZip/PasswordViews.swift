import SwiftUI
import ArchiveKit

/// Asks for the password of an encrypted archive (HLD §20, Phase 5).
struct PasswordSheet: View {
    let model: ArchiveBrowserModel
    @State private var password = ""
    @State private var remember = false
    @State private var isChecking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter the password for “\(model.archiveURL?.lastPathComponent ?? "")”")
                        .font(.headline)
                    Text(model.passwordPromptDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(unlock)
            if let failure = model.passwordFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelPasswordPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !isChecking else { return }
        isChecking = true
        let attempt = password
        Task {
            let accepted = await model.submitPassword(attempt, remember: remember)
            isChecking = false
            if !accepted { password = ""; isFocused = true }
        }
    }
}

/// The banner shown while an archive has password-protected items and no
/// password has been entered.
struct PasswordBanner: View {
    let count: Int
    let model: ArchiveBrowserModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count) items are password-protected.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Enter Password…") { model.requestPassword() }
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
