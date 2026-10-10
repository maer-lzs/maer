// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 🔴 THE one answer to "which local subscriptions does
/// gpodder see". Two comparison sets carried the rule before. The conflict
/// snapshot had both halves, the main reconcile only the token half, and its
/// own comment promised the mirror exclusion it did not implement. Every
/// capsule-carrying device therefore pushed the Pinchflat mirror URLs, and
/// every device without mesh access inherited them as dead "premium" feeds
///.
///
/// Third instance of the class "rule sits only where it was reported", so
/// this is a CONSOLIDATION, not a copied filter: both call sites read this
/// type, and a project fence keeps a future third comparison set from
/// re-opening the asymmetry.
///
/// Two exclusions, two different reasons. Both permanent:
/// * **Token feeds**: pushing them would hand the secret to the server.
/// * **Mirrors** (`origin != nil`): a mirrored server group is not
///   the user's subscription set, and mesh-less devices would inherit feeds
///   they can never reach.
nonisolated enum GPodderVisibleSubscriptions {
    struct Result {
        /// normalized feed URL → raw feed URL, for everything gpodder compares.
        let byNorm: [String: String]
        /// Normalized URLs that exist locally but stay INVISIBLE to gpodder.
        /// They must not be re-adopted from the server either: a mirror or
        /// token feed sitting on the server (pushed before this rule) is a
        /// leftover to converge away, never a subscription to add locally.
        let hiddenNorms: Set<String>
    }

    /// Split the local subscription list into what gpodder may compare and
    /// what stays local-only. Pure over the passed list. The `current()`
    /// convenience reads the live store.
    /// `premiumOptIn` is the per-account switch "my own server may
    /// carry my premium feeds". It lifts the TOKEN exclusion only. Mirrors
    /// stay hidden in every case, and the Basic-auth class travels through
    /// the iCloud channel instead (a URL without its credentials would be
    /// half a state).
    static func split(_ shows: [(feedURL: String, origin: String?)],
                      premiumOptIn: Bool = false) -> Result {
        var byNorm: [String: String] = [:]
        var hidden = Set<String>()
        for show in shows {
            let norm = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            let tokenHidden = PodcastSubscriptions.isTokenFeedURL(show.feedURL) && !premiumOptIn
            if tokenHidden || show.origin != nil {
                hidden.insert(norm)
            } else if byNorm[norm] == nil {
                byNorm[norm] = show.feedURL
            }
        }
        // A URL that appears both ways (same show mirrored AND subscribed
        // directly) stays visible. The direct subscription is the user's.
        hidden.subtract(byNorm.keys)
        return Result(byNorm: byNorm, hiddenNorms: hidden)
    }

    /// The SERVER side of the same question. Which of the server's
    /// URLs does this device see at all? With the premium opt-in off, token
    /// feeds are invisible in BOTH directions: not adopted, not cleaned up.
    /// (Without this the asymmetry became a tug-of-war: one device pushes,
    /// the other adopts and then removes it again.) The rule lives HERE, so
    /// the fence that keeps it in one place stays honest.
    static func visibleServerURLs(_ byNorm: [String: String],
                                  premiumOptIn: Bool,
                                  leftOnServer: Set<String>) -> [String: String] {
        let found = withoutLeftOnServer(byNorm, leftOnServer)
        guard !premiumOptIn else { return found }
        return found.filter { !PodcastSubscriptions.isTokenFeedURL($0.value) }
    }

    /// The feeds found only on the server when this device went on with
    /// another account (`GPodderSync.continueWithThisAccount`): they came
    /// from the account before and stay where they are. Invisible in BOTH
    /// directions, like the token feeds: never taken into this account's
    /// subscriptions, never removed from the gpodder server.
    static func withoutLeftOnServer(_ byNorm: [String: String], _ leftOnServer: Set<String>) -> [String: String] {
        guard !leftOnServer.isEmpty else { return byNorm }
        return byNorm.filter { !leftOnServer.contains($0.key) }
    }

    /// Which server feeds stay there when this device goes on with another
    /// account: every one the server holds that this device does not.
    static func leftOnServer(server: Set<String>, local: Set<String>) -> Set<String> {
        server.subtracting(local)
    }

    /// A left feed this device subscribes itself later is shared again: it
    /// leaves the list, so the round sees it on the server and does not read
    /// its absence there as a removal made elsewhere.
    static func stillLeft(_ stored: Set<String>, local: Set<String>) -> Set<String> {
        stored.subtracting(local)
    }

    /// The stored list, kept to what is still left.
    @MainActor
    static func currentLeftOnServer(local: Set<String>) -> Set<String> {
        let stored = Set(AppStorageKeys.stringArray(AppStorageKeys.gpodderLeftOnServer) ?? [])
        let left = stillLeft(stored, local: local)
        if left != stored { AppStorageKeys.set(Array(left), for: AppStorageKeys.gpodderLeftOnServer) }
        return left
    }

    @MainActor
    static func current() -> Result {
        split(PodcastSubscriptions.shared.shows.map { ($0.feedURL, $0.origin) },
              premiumOptIn: AppStorageKeys.gpodderSyncsPremiumFeedsEnabled)
    }
}
