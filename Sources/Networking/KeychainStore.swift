import Foundation
import OSLog
import Security

/// Very simple keychain wrapper. Enough for a single-user app — no third-party
/// dependency needed. `nonisolated`: the Security-framework `SecItem*` calls are
/// thread-safe, so credential access must be usable from background/nonisolated
/// contexts (the project uses default MainActor isolation).
nonisolated enum KeychainStore {
    // IMPORTANT: adjust to your actual bundle id (see README).
    private static let service = "com.example.absplayer"

    static func save(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Y26: readable after the first unlock — without this the default
        // (WhenUnlocked) makes every background/locked read fail, and a failed
        // credential read used to cascade into "source logged out".
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // Y26 diagnosis: an unreadable item is NOT the same as a missing
            // one — log every non-notFound failure (e.g. -25308
            // interactionNotAllowed while the device is locked).
            if status != errSecItemNotFound {
                Logger.library.error("keychain read for \(key, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated enum KeychainKey {
    static let serverURL = "serverURL"
    static let apiToken = "apiToken"
    static let podcastIndexSecret = "podcastIndexSecret"
    static let gpodderPassword = "gpodderPassword"
    static let subsonicPassword = "subsonicPassword"
}
