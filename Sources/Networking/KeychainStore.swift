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

    /// Default accessibility is AfterFirstUnlock. Without it the
    /// WhenUnlocked default makes every background/locked read fail, and a
    /// failed credential read used to cascade into "source logged out".
    /// The parameter is for the items that never leave this device
    /// (`ThisDeviceOnly`).
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

    /// Every item whose account starts with `prefix`, as account to value.
    ///
    /// A class that has to travel as a whole needs to know what it consists
    /// of, so the keychain has a listing door.
    ///
    /// `SynchronizableAny`, because a plain listing means "local items only", and the one class that lives
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
        read(forKey: key).value
    }

    /// The same read, saying whether a missing value is missing or could
    /// not be read (`KeychainRead`).
    static func read(forKey key: String) -> KeychainRead {
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
        let read = KeychainRead.of(status: status, data: result as? Data)
        // An unreadable item is NOT the same as a missing one. Log every
        // non-notFound failure (e.g. -25308 interactionNotAllowed while the
        // device is locked).
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.library.error("keychain read for \(key, privacy: .public) failed: \(status)")
        }
        return read
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

/// What a read of one item found. An item that could not be read (the
/// device not yet unlocked since it started, -25308) is not a missing one:
/// a reader that holds the answer for the process asks again later.
nonisolated enum KeychainRead: Equatable, Sendable {
    case value(String)
    case missing
    case unreadable

    /// Bytes that do not decode are no access, and reading them again does
    /// not change that: missing, as the plain read always answered.
    static func of(status: OSStatus, data: Data?) -> KeychainRead {
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unreadable }
        guard let data, let text = String(data: data, encoding: .utf8) else { return .missing }
        return .value(text)
    }

    var value: String? {
        if case .value(let text) = self { return text }
        return nil
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
