import Foundation
import Security

/// Optional Keychain storage for archive passwords (HLD §20, Phase 5).
///
/// A password is stored only when the user ticks "Remember in Keychain",
/// as a generic password in the login keychain under the archive's path,
/// and is never logged or written anywhere else.
enum PasswordVault {
    /// Derived from the bundle identifier, which each developer sets in
    /// Config/Local.xcconfig, so no identifier is hard-coded here.
    private static let service = (Bundle.main.bundleIdentifier ?? "QuickZip") + ".archive-password"

    private static func query(for archive: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archive.standardizedFileURL.path,
        ]
    }

    static func password(for archive: URL) -> String? {
        var request = query(for: archive)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for archive: URL) -> Bool {
        var request = query(for: archive)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ password: String, for archive: URL) -> Bool {
        delete(for: archive)
        var item = query(for: archive)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "QuickZip archive password"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(for archive: URL) {
        SecItemDelete(query(for: archive) as CFDictionary)
    }
}
