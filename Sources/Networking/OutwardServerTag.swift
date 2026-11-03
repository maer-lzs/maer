// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CryptoKit
import Foundation
import OSLog
import Security

/// The tag an outward id carries for its server (`OutwardItemRef`): a keyed
/// hash over the server's one name with a salt of this device.
///
/// The name is the key of `ServerAddressSwitch`: what is no switch there
/// keeps its tag here (http and https, the default port, case, a trailing
/// slash), and another host, port or path gives another tag.
///
/// The salt is random, made once, and lives in the keychain of this device
/// only: never synchronized, and a backup restored onto other hardware
/// leaves it behind. Without the key a guessed server name does not give
/// the tag, and two devices give two tags for the same server.
///
/// A salt is made only when the keychain answers that there is none. A read
/// that fails gives no salt and writes nothing, so a locked keychain never
/// replaces the salt and every outward id with it.
nonisolated enum OutwardServerTag {
    /// The keychain account of the salt.
    static let saltAccount = "outwardSalt"
    /// Bytes of a new salt.
    static let saltLength = 32

    /// The tag of `owner` (a name as `ItemOwners` holds it) under `salt`;
    /// nil for a name that reads as no address.
    static func tag(owner: String, salt: Data) -> String? {
        guard let key = ServerAddressSwitch.serverKey(of: owner) else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data(key.utf8), using: SymmetricKey(data: salt))
        let hex = code.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(OutwardItemRef.tagLength))
    }

    /// The tag of each library id's owner under `salt`; nil for an id the
    /// register does not name.
    static func tagOf(owners: ItemOwners, salt: Data) -> (String) -> String? {
        { itemId in owners.owner(of: itemId).flatMap { tag(owner: $0, salt: salt) } }
    }

    /// The salt as the keychain answers: the stored one, a new one when
    /// there is none and it could be written, or nil.
    static func salt(read: () -> KeychainRead, write: (String) -> Bool, random: () -> Data) -> Data? {
        switch read() {
        case .value(let text):
            guard let salt = Data(base64Encoded: text), salt.count == saltLength else {
                Logger.library.error("OUTWARD salt unusable, no outward ids")
                return nil
            }
            return salt
        case .missing:
            let salt = random()
            guard salt.count == saltLength, write(salt.base64EncodedString()) else {
                Logger.library.error("OUTWARD salt not written, no outward ids")
                return nil
            }
            Logger.library.notice("OUTWARD salt made")
            return salt
        case .unreadable, .undecodable:
            Logger.library.error("OUTWARD salt unreadable, no outward ids")
            return nil
        }
    }

    /// The salt of this device, from the keychain.
    static func appSalt() -> Data? {
        salt(read: { KeychainStore.read(forKey: saltAccount) },
             write: { KeychainStore.save($0, forKey: saltAccount,
                                         accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) },
             random: { Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max) }) })
    }

    /// The tags of this device: its salt over the owner register. Nil when
    /// either is unavailable; then no outward id is handed out.
    static func appTagOf() -> ((String) -> String?)? {
        guard let owners = ItemOwnerShelf.app?.read().value else {
            Logger.library.notice("OUTWARD no owner register, no outward ids")
            return nil
        }
        guard let salt = appSalt() else { return nil }
        return tagOf(owners: owners, salt: salt)
    }
}
