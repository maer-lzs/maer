// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 🔴 P1 (iPad round): THE one answer to "which local subscriptions does
/// gpodder see". Two comparison sets carried the rule before — the conflict
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
/// Two exclusions, two different reasons — both permanent:
/// * **Token feeds** (Y52): pushing them would hand the secret to the server.
/// * **Mirrors** (`origin != nil`, a7fa35e): a mirrored server group is not
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
    /// what stays local-only. Pure over the passed list — the `current()`
    /// convenience reads the live store.
    /// P2 (1): `premiumOptIn` is the per-account switch "my own server may
    /// carry my premium feeds". It lifts the TOKEN exclusion only — mirrors
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
        // directly) stays visible — the direct subscription is the user's.
        hidden.subtract(byNorm.keys)
        return Result(byNorm: byNorm, hiddenNorms: hidden)
    }

    /// 24857d7: the SERVER side of the same question — which of the server's
    /// URLs does this device see at all? With the premium opt-in off, token
    /// feeds are invisible in BOTH directions: not adopted, not cleaned up.
    /// (Without this the asymmetry became a tug-of-war: one device pushes,
    /// the other adopts and then removes it again.) The rule lives HERE, so
    /// the fence that keeps it in one place stays honest.
    static func visibleServerURLs(_ byNorm: [String: String],
                                  premiumOptIn: Bool) -> [String: String] {
        guard !premiumOptIn else { return byNorm }
        return byNorm.filter { !PodcastSubscriptions.isTokenFeedURL($0.value) }
    }

    @MainActor
    static func current() -> Result {
        split(PodcastSubscriptions.shared.shows.map { ($0.feedURL, $0.origin) },
              premiumOptIn: AppStorageKeys.gpodderSyncsPremiumFeedsEnabled)
    }
}
