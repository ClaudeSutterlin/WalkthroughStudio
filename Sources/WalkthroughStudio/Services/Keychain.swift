import Foundation
import Security

/// Minimal Keychain wrapper for API keys (spec: never write keys to disk in plaintext).
enum Keychain {
    private static let service = "com.walkthroughstudio.app"

    static let anthropicAccount = "anthropic-api-key"
    static let elevenLabsAccount = "elevenlabs-api-key"

    /// Per-launch cache so we hit the keychain (and any access prompt) at most
    /// once per key per run. Lock-guarded — reads can come from a background
    /// task (e.g. the launch-time setup check).
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

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
            setCached("", account: account)
            return true
        }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            setCached(nil, account: account)
            return false
        }
        setCached(value, account: account)
        return true
    }

    static func read(account: String) -> String {
        lock.lock()
        let cached = cache[account]
        lock.unlock()
        if let cached { return cached }

        if let value = copyValue(service: service, account: account) {
            setCached(value, account: account)
            return value
        }
        return ""
    }

    private static func copyValue(service: String, account: String) -> String? {
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
        else { return nil }
        return string
    }

    private static func setCached(_ value: String?, account: String) {
        lock.lock()
        cache[account] = value
        lock.unlock()
    }

    static var anthropicKey: String { read(account: anthropicAccount) }
    static var elevenLabsKey: String { read(account: elevenLabsAccount) }
}
