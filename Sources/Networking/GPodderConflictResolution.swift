// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pure, tested resolution of a gpodder subscription conflict that the
/// mass-delete guard (`GPodderSubscriptionMerge`) left UNresolved. Operates on
/// normalized feed keys; the caller maps them back to raw URLs to apply. Reuses
/// the same set model as the merge. No second diff logic.
nonisolated enum GPodderConflictResolution {
    /// Per-feed decision. `keepLocal` = the final state matches what LOCAL has
    /// for this feed; `takeServer` = it matches the SERVER. (For a feed present
    /// on exactly one side, that means include-if-that-side-has-it.)
    enum Choice: Equatable { case keepLocal, takeServer }

    /// The concrete actions to converge, plus the resulting synced set.
    struct Actions: Equatable {
        var subscribeLocally: Set<String> = []    // server-only feeds to add locally
        var unsubscribeLocally: Set<String> = []  // local-only feeds to drop locally
        var addToServer: Set<String> = []         // local-only feeds to push to the server
        var removeFromServer: Set<String> = []    // server-only feeds to drop from the server
        var converged: Set<String> = []           // → gpodderLastSyncedFeeds
    }

    /// Feeds present on exactly one side, as the page shows them: what
    /// only this device has, then what only the server has, each sorted
    /// for a stable order. Both empty means no conflict.
    static func conflictingFeeds(local: Set<String>, server: Set<String>)
        -> (localOnly: [String], serverOnly: [String]) {
        (local.subtracting(server).sorted(), server.subtracting(local).sorted())
    }

    /// Turn per-feed choices into apply actions + the converged set. A feed with
    /// NO explicit choice defaults to UNION (keep whichever side has it → nothing
    /// is lost), the safe pre-selection. The feeds it decides are the ones the
    /// page shows: both come from `conflictingFeeds`, the one root.
    static func resolve(local: Set<String>, server: Set<String>,
                        choices: [String: Choice]) -> Actions {
        var actions = Actions()
        actions.converged = local.intersection(server)   // agreed feeds always stay
        let sides = conflictingFeeds(local: local, server: server)
        for feed in sides.localOnly + sides.serverOnly {
            let onLocal = local.contains(feed)
            let choice = choices[feed] ?? (onLocal ? .keepLocal : .takeServer)   // union default
            let include = (choice == .keepLocal) ? onLocal : !onLocal
            if include {
                actions.converged.insert(feed)
                if onLocal { actions.addToServer.insert(feed) }       // local has it → push
                else { actions.subscribeLocally.insert(feed) }        // server has it → subscribe
            } else {
                if onLocal { actions.unsubscribeLocally.insert(feed) } // drop locally
                else { actions.removeFromServer.insert(feed) }         // drop from server
            }
        }
        return actions
    }

    /// The synced set after applying, built from what landed: the feeds both
    /// sides agreed on and those kept from here, plus every feed taken from
    /// the server that was subscribed here. A feed taken from the server and
    /// not subscribed (set out, held on Audiobookshelf, a failed fetch) is on
    /// the server and not here; counted as synced, the next round would take
    /// its absence here for a removal and send it to the server.
    static func synced(_ actions: Actions, subscribed: Set<String>) -> Set<String> {
        actions.converged.subtracting(actions.subscribeLocally)
            .union(subscribed.intersection(actions.subscribeLocally))
    }
}
