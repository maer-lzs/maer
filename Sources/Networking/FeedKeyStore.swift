// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Security

/// Where `feed` of the one-secret derivation lives: the keychain of THIS
/// device, one item per service, never in a backup and never in the iCloud
/// keychain. It comes only from a password the service has never seen (the
/// new one of a move or a change, or one that only ever travelled as its
/// proof), so the service cannot open what is sealed with it.
///
/// The feed credential blocks are sealed with it (envelope 2,
/// `FeedAuthCrypto.seal(_:feed:)`). Every device that signed in with the
/// password holds the same one, so no code has to travel between them.
nonisolated enum FeedKeyStore {
    /// The keychain account for one service: host and port, lowercased,
    /// like the held service key.
    static func account(for baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else { return nil }
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "maerSyncFeed:\(host)\(port)"
    }

    static func keep(_ feed: Data, for baseURL: URL) {
        guard let account = account(for: baseURL), feed.count == 32 else { return }
        let saved = KeychainStore.save(feed.base64EncodedString(), forKey: account,
                                       accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        Logger.library.notice("MAERSYNC feed key kept=\(saved, privacy: .public)")
    }

    static func held(for baseURL: URL) -> Data? {
        guard let account = account(for: baseURL),
              let stored = KeychainStore.load(forKey: account), !stored.isEmpty else { return nil }
        return Data(base64Encoded: stored)
    }

    static func forget(for baseURL: URL) {
        guard let account = account(for: baseURL) else { return }
        KeychainStore.delete(forKey: account)
    }
}
