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

    /// Optional: an Admin API key (`sk-ant-admin01-…`) that lets Peeky read
    /// the organization's real spend. Store with
    /// `security add-generic-password -s MyClicky -a anthropic-admin -w KEY`.
    static func anthropicAdminKey() -> String? {
        read(account: "anthropic-admin")
    }

    /// Per-process cache. Every read goes through SecItemCopyMatching, which
    /// blocks the calling thread while any keychain prompt is up — and the
    /// unread watchers, planner and services all read on the main thread.
    private static var cache: [String: String] = [:]

    static func read(account: String) -> String? {
        if let cached = cache[account] { return cached }
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
        cache[account] = value
        adoptIfNeeded(account: account, value: value)
        return value
    }

    /// Items created in Terminal via the `security` CLI trigger a keychain
    /// password prompt every time this app reads them (partition-list quirk).
    /// After the first successful read, rewrite the item so it is owned by
    /// this app — future reads are then prompt-free, even across rebuilds
    /// (the installed app is signed with a stable identity).
    ///
    /// Only the installed copy may do this, and only once per item: rewriting
    /// replaces the item's access list, so an unsigned `swift build` binary
    /// adopting it would lock the installed app out (and vice versa), with
    /// every launch of either one prompting for the keychain password again.
    private static let adoptedDefaultsKey = "keychainAdoptedAccounts"
    private static var isInstalledCopy: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
    private static func adoptIfNeeded(account: String, value: String) {
        guard isInstalledCopy else { return }
        var adopted = Set(UserDefaults.standard.stringArray(forKey: adoptedDefaultsKey) ?? [])
        guard !adopted.contains(account) else { return }
        if save(account: account, value: value) {
            adopted.insert(account)
            UserDefaults.standard.set(Array(adopted).sorted(), forKey: adoptedDefaultsKey)
        }
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
        let ok = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        if ok { cache[account] = value } else { cache[account] = nil }
        return ok
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MyClicky",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cache[account] = nil
    }
}
