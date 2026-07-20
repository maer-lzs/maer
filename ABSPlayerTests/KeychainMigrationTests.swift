// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
import Security
@testable import ABSPlayer

/// Y34: legacy keychain items (WhenUnlocked) are rewritten once with
/// AfterFirstUnlock; the flag only sets on a successful pass.
struct KeychainMigrationTests {
    private func accessibility(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    @Test("a legacy WhenUnlocked item is rewritten to AfterFirstUnlock, value intact")
    func migratesLegacyItem() {
        let key = "test.migration.\(UUID().uuidString)"
        let flag = "test.migrationFlag.\(UUID().uuidString)"
        defer {
            KeychainStore.delete(forKey: key)
            UserDefaults.standard.removeObject(forKey: flag)
        }
        // Legacy shape: explicitly WhenUnlocked.
        KeychainStore.save("secret", forKey: key, accessible: kSecAttrAccessibleWhenUnlocked)
        #expect(accessibility(forKey: key) == (kSecAttrAccessibleWhenUnlocked as String))

        KeychainStore.migrateAccessibilityOnce(flagKey: flag)

        #expect(accessibility(forKey: key) == (kSecAttrAccessibleAfterFirstUnlock as String))
        #expect(KeychainStore.load(forKey: key) == "secret")
        #expect(UserDefaults.standard.bool(forKey: flag))

        // Second run is a no-op (flag set) — rewrite a legacy item and verify
        // it stays untouched.
        KeychainStore.save("secret2", forKey: key, accessible: kSecAttrAccessibleWhenUnlocked)
        KeychainStore.migrateAccessibilityOnce(flagKey: flag)
        #expect(accessibility(forKey: key) == (kSecAttrAccessibleWhenUnlocked as String))
    }
}
#endif
