import Foundation
import Security

/// Minimal Keychain wrapper for API keys (spec: never write keys to disk in plaintext).
enum Keychain {
    private static let service = "com.walkthroughstudio.app"

    static let anthropicAccount = "anthropic-api-key"
    static let elevenLabsAccount = "elevenlabs-api-key"

    /// Per-launch cache so we hit the keychain (and any access prompt) at most
    /// once per key per run.
    private static var cache: [String: String] = [:]

    /// Returns false when the keychain rejected the write. The old item is
    /// deleted first (see below), so a failed add means the key is NOT stored —
    /// the cache is dropped rather than left masking the loss until relaunch.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add (rather than update) so saving a key from the current
        // build makes this app the item's creator — no access prompt afterwards,
        // even if the item was created by a differently-signed older build.
        SecItemDelete(query as CFDictionary)
        if value.isEmpty {
            cache[account] = ""
            return true
        }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            cache[account] = nil
            return false
        }
        cache[account] = value
        return true
    }

    static func read(account: String) -> String {
        if let cached = cache[account] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        cache[account] = string
        return string
    }

    static var anthropicKey: String { read(account: anthropicAccount) }
    static var elevenLabsKey: String { read(account: elevenLabsAccount) }
}
