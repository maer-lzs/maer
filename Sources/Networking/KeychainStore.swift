// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Security

/// Very simple keychain wrapper. Enough for a single-user app. No third-party
/// dependency needed. `nonisolated`: the Security-framework `SecItem*` calls are
/// thread-safe, so credential access must be usable from background/nonisolated
/// contexts (the project uses default MainActor isolation).
nonisolated enum KeychainStore {
    // IMPORTANT: adjust to your actual bundle id (see README).
    /// Internal (not private) so the migration test can query attributes of
    /// items under the real service.
    static let service = "com.example.absplayer"

    /// Default accessibility is AfterFirstUnlock. Without it the
    /// WhenUnlocked default makes every background/locked read fail, and a
    /// failed credential read used to cascade into "source logged out".
    /// The parameter exists for tests that need to construct legacy items.
    /// `synchronizable` puts an item into the iCloud keychain. The
    /// channel for what gpodder cannot carry (Basic-auth credentials). URL
    /// and secret are a PAIR: whoever stores one synchronized must store the
    /// other the same way, or a second device inherits half a state.
    static func save(_ value: String, forKey key: String,
                     accessible: CFString = kSecAttrAccessibleAfterFirstUnlock,
                     synchronizable: Bool = false) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessible
        if synchronizable { attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// One-time migration for EXISTING installs. Items written before
    /// the Y26 fix carry WhenUnlocked and stay unreadable for background work
    /// (the nightly refresh, running for real since Y32, read them into the
    /// void on a locked device); the ABS token would otherwise only be
    /// rewritten at the next login. Rewrites every READABLE item of our
    /// service with the new accessibility. Runs in the foreground (device
    /// unlocked → reads succeed); the flag is only set after a successful
    /// pass, so a failed attempt retries on the next start.
    static func migrateAccessibilityOnce(
        flagKey: String = "keychainAccessibilityMigrated",
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: flagKey) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            var migrated = 0
            for item in (result as? [[String: Any]]) ?? [] {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                save(value, forKey: account)
                migrated += 1
            }
            Logger.library.log("keychain accessibility migration: \(migrated) items rewritten")
            defaults.set(true, forKey: flagKey)
        case errSecItemNotFound:
            defaults.set(true, forKey: flagKey)   // nothing to migrate
        default:
            // Locked or transient. Keep the flag unset, retry next start.
            Logger.library.error("keychain migration attempt failed: \(status)")
        }
    }

    static func load(forKey key: String) -> String? {
        // Synchronizable ANY: a device that inherited an item through the
        // iCloud keychain must find it here, and a local item must keep
        // being found after the switch was flipped.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // An unreadable item is NOT the same as a missing
            // one. Log every non-notFound failure (e.g. -25308
            // interactionNotAllowed while the device is locked).
            if status != errSecItemNotFound {
                Logger.library.error("keychain read for \(key, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 🔴 Every deletion names its CALLER. the user also
    /// lost the Subsonic password, for which no automatic deletion path is
    /// measurable. So the next incident must leave a trail instead of a
    /// guess. Only the key name is logged, never a value.
    static func delete(forKey key: String, caller: StaticString = #function,
                       file: StaticString = #fileID) {
        // `kSecAttrSynchronizableAny`: a delete must reach BOTH worlds.
        // Otherwise a synchronized twin survives an apparent deletion.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        Logger.library.notice("KEYCHAIN delete key=\(key, privacy: .public) by=\(String(describing: file), privacy: .public)#\(String(describing: caller), privacy: .public) status=\(status)")
    }
}

nonisolated enum KeychainKey {
    static let serverURL = "serverURL"
    static let apiToken = "apiToken"
    static let podcastIndexSecret = "podcastIndexSecret"
    static let gpodderPassword = "gpodderPassword"
    static let subsonicPassword = "subsonicPassword"
    static let jellyfinPassword = "jellyfinPassword"
    static let jellyfinToken = "jellyfinToken"
}
