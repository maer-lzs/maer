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
    static let service = "fm.maer.app"

    /// The service name of the identity-move era before this one. Its
    /// items are unreadable dead weight once the app writes under the new
    /// service; the one-time purge below removes them instead of leaving
    /// them in the keychain forever.
    static let retiredService = "com.example.absplayer"

    /// One-time hygiene after the service rename: delete every item left
    /// under the retired service (local and synchronized twins). The flag
    /// is set even when nothing was found; there is nothing to retry.
    static func purgeRetiredServiceOnce(
        flagKey: String = "keychainRetiredServicePurged",
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: flagKey) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: retiredService,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        defaults.set(true, forKey: flagKey)
        Logger.library.notice("KEYCHAIN retired-service purge: \(status == errSecSuccess ? "removed" : "nothing there", privacy: .public)")
    }

    /// Default accessibility is AfterFirstUnlock. Without it the
    /// WhenUnlocked default makes every background/locked read fail, and a
    /// failed credential read used to cascade into "source logged out".
    /// The parameter exists for tests that need to construct legacy items.
    /// `synchronizable` puts an item into the iCloud keychain. The
    /// channel for what gpodder cannot carry (Basic-auth credentials). URL
    /// and secret are a PAIR: whoever stores one synchronized must store the
    /// other the same way, or a second device inherits half a state.
    /// Returns whether the item was written. A caller that books a moment
    /// for a write must book it only when this says so.
    /// `adding` is the add itself, handed in so a witness can let it fail;
    /// the app passes nothing.
    @discardableResult
    static func save(_ value: String, forKey key: String,
                     accessible: CFString = kSecAttrAccessibleAfterFirstUnlock,
                     synchronizable: Bool = false,
                     adding: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }) -> Bool {
        let data = Data(value.utf8)
        // The place is part of the item's identity: Apple keeps a local and
        // a synchronized item under the same account as TWO items, and
        // that is the twin every save has to deal with.
        var place: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        ]
        // The new place stands BEFORE the other world is cleared. A save
        // that cleared both worlds first and added after lost the item when
        // the add failed, and the answer said only `false`; for one password
        // a person types that was a retry, for the rewrite of every feed
        // credential at a sign-in it was a lost access to a paid feed.
        var add = place
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        var status = adding(add as CFDictionary)
        if status == errSecDuplicateItem {
            // Same key, same place: the item is updated, not doubled. This
            // is the case that once wrote NOTHING when the clearing missed
            // the synchronized twin.
            let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
            status = SecItemUpdate(place as CFDictionary, update as CFDictionary)
        }
        // The status is READ, like at the three other calls of this file:
        // this is the call that carries the person's change.
        guard status == errSecSuccess else {
            Logger.library.error("keychain write for \(key, privacy: .public) failed: \(status)")
            return false
        }
        // Only now the twin in the OTHER world goes, so the switch and the
        // service really move an item instead of doubling it.
        place[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanFalse : kCFBooleanTrue
        SecItemDelete(place as CFDictionary)
        return true
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
            // Without this the listing means "local items only", so the
            // items in the iCloud keychain never got this healing, and
            // those are the feed credentials.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
                // The rewrite KEEPS the item where it lives. Since the
                // listing above reaches the iCloud keychain too, writing
                // with the plain default would quietly move those items
                // out of it, and the one class that lives there is the feed
                // credentials: a healing that takes a channel away is not
                // a healing.
                let travels = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
                save(value, forKey: account, synchronizable: travels)
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

    /// Every item whose account starts with `prefix`, as account to value.
    ///
    /// The door had `load`, `save` and `delete`, each for ONE key, and the
    /// only place that ever listed was the one-shot accessibility healing.
    /// A class that has to travel as a whole needs to know what it consists
    /// of, so the listing is a door now instead of living inside a healing.
    ///
    /// `SynchronizableAny` for the same reason it stands in the healing: a
    /// plain listing means "local items only", and the one class that lives
    /// in the iCloud keychain is the feed credentials, so a listing without
    /// it would answer about everything except the thing being asked about.
    ///
    /// **Nil is not empty.** A locked or failing keychain answers nil, an
    /// empty dictionary means the listing worked and there is nothing. The
    /// two must not collapse: "this person has no credentials" is exactly
    /// the reading that would let a caller write an empty block over a full
    /// one, and a locked keychain is the state a background launch is most
    /// likely to be in.
    static func values(withPrefix prefix: String) -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Not found IS an answer: the listing worked and there is nothing.
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else {
            Logger.library.error("keychain listing failed: \(status)")
            return nil
        }
        var out: [String: String] = [:]
        for item in (result as? [[String: Any]]) ?? [] {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix),
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            out[account] = value
        }
        return out
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
    static let maerSyncToken = "maerSyncToken"
}
