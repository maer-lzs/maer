// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Feeds that arrived over the account (subscription family) but answered
/// this device's adoption with a sign-in demand. The login is device
/// state, so the other device's subscription cannot be followed until the
/// person signs in here. The marker stops the endless retry: an adoption
/// skips a marked feed until a login is saved or the person removes it.
/// Pure rules over a UserDefaults dictionary (feed key ⇒ feed address).
nonisolated enum FeedSignInPending {
    /// The two answers that mean "credentials", not "gone" or "down".
    static func demandsSignIn(status: Int?) -> Bool {
        status == 401 || status == 403
    }

    static func pending(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: AppStorageKeys.podcastFeedsNeedingSignIn) as? [String: String] ?? [:]
    }

    /// May the adoption fetch this feed? No while it is marked.
    static func shouldAttempt(feedKey: String, defaults: UserDefaults = .standard) -> Bool {
        pending(defaults: defaults)[feedKey] == nil
    }

    static func mark(feedKey: String, feedURL: String, defaults: UserDefaults = .standard) {
        var map = pending(defaults: defaults)
        map[feedKey] = feedURL
        defaults.set(map, forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
    }

    /// Idempotent: clearing an unmarked key changes nothing.
    static func clear(feedKey: String, defaults: UserDefaults = .standard) {
        var map = pending(defaults: defaults)
        guard map.removeValue(forKey: feedKey) != nil else { return }
        if map.isEmpty {
            defaults.removeObject(forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        } else {
            defaults.set(map, forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        }
    }
}
