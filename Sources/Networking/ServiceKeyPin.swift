// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Security

/// Where this device holds on to a service's static key, and why it holds it
/// HERE and nowhere else.
///
/// **It never travels, and that is the invariant the whole point stands on.**
/// A pin that travelled over the very channel it protects would cancel
/// itself: whoever could plant a document in the sync could plant the pin
/// beside it, and the device would trust exactly the key the attacker wanted.
/// So nothing here is `synchronizable`, and a fence holds that the word never
/// appears in this file.
///
/// **And it is not in a backup either, which is one step further than the
/// device link code goes.** That one uses the ordinary accessibility, and
/// rightly: it is a RECOVERY key, and losing it with a broken phone would
/// lose the feed credentials for good. A pin is the opposite kind of thing.
/// It is a memory of a MEETING, and a device restored from a backup has not
/// met anything. Carrying the memory over would mean a new device trusting a
/// key it never saw offered, which is the one thing first use is supposed to
/// establish. So: `ThisDeviceOnly`, and a new device meets the service again.
///
/// **Per service address**, because a person can point the app at a different
/// service, and the second one is not the first one changing its key.
nonisolated enum ServiceKeyPin {
    /// The keychain account for one service address.
    ///
    /// The HOST and the port, not the whole address: a path or a query does
    /// not make it a different service, and a trailing slash certainly does
    /// not. Lowercased, because a host is case insensitive and a person who
    /// retypes it with a capital would otherwise be meeting a stranger.
    static func account(for baseURL: URL) -> String? {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else { return nil }
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "serviceKeyPin:\(host)\(port)"
    }

    /// The fingerprint this device is holding for that service, or nil.
    static func held(for baseURL: URL) -> String? {
        guard let account = account(for: baseURL) else { return nil }
        let stored = KeychainStore.load(forKey: account)
        return (stored?.isEmpty ?? true) ? nil : stored
    }

    /// Hold on to a fingerprint for that service.
    ///
    /// Deliberately blunt: it overwrites. The guard against overwriting by
    /// accident is not here but in `ServiceKeyTrust`, which is pure and
    /// testable, and in the one caller that has a changed key in hand and a
    /// person's answer to go with it.
    static func hold(_ fingerprint: String, for baseURL: URL) {
        guard let account = account(for: baseURL), !fingerprint.isEmpty else { return }
        KeychainStore.save(fingerprint, forKey: account,
                           accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        Logger.library.log("service key pinned")
    }

    // There is deliberately no way to let go. A sign out keeps the pin: the
    // pin's whole worth is that a different key is an EVENT, and a sign out
    // is not a reason to forget whom this device has met. A service that
    // really changed its key is accepted through the event, and accepting
    // overwrites.
}
