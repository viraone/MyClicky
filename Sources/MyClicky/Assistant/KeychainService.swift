import Foundation
import Security

/// Reads the Anthropic API key from the macOS Keychain.
///
/// One-time setup in Terminal:
///   security add-generic-password -s MyClicky -a anthropic -w YOUR_API_KEY
enum KeychainService {
    static let setupCommand = "security add-generic-password -s MyClicky -a anthropic -w YOUR_API_KEY"

    static func anthropicAPIKey() -> String? {
        read(account: "anthropic")
    }

    /// Optional: workspace ID for identity-linked API keys.
    static func anthropicWorkspaceID() -> String? {
        read(account: "anthropic-workspace")
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MyClicky",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        adoptIfNeeded(account: account, value: value)
        return value
    }

    /// Items created in Terminal via the `security` CLI trigger a keychain
    /// password prompt every time this app reads them (partition-list quirk).
    /// After the first successful read, rewrite the item so it is owned by
    /// this app — future reads are then prompt-free, even across rebuilds.
    private static var adopted = Set<String>()
    private static func adoptIfNeeded(account: String, value: String) {
        guard !adopted.contains(account) else { return }
        adopted.insert(account)
        save(account: account, value: value)
    }

    @discardableResult
    static func save(account: String, value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MyClicky",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MyClicky",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
