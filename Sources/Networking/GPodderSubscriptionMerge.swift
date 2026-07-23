// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure 3-way merge decision for the gpodder subscription sync, extracted so
/// the mass-delete guard is unit-testable. A server answer that is empty or
/// sharply shortened must not translate into local mass-unsubscribes.
nonisolated struct GPodderSubscriptionMerge: Equatable {
    var addToServer: Set<String> = []
    var addLocally: Set<String> = []
    var removeFromServer: Set<String> = []
    var removeLocally: Set<String> = []
    /// The removals the guard BLOCKED (would have happened without the guard).
    /// Kept for the diagnostic log so a suspected loss can be traced whether the
    /// remove was applied or vetoed — they are NOT applied.
    var blockedRemoveLocally: Set<String> = []
    var blockedRemoveFromServer: Set<String> = []
    /// The 2–3-feed removals awaiting a SECOND consecutive confirmation — held
    /// this run, persisted, and applied only if the same diff still stands next
    /// run. Caller stores these and feeds them back as `pendingRemove*`.
    var pendingRemoveLocally: Set<String> = []
    var pendingRemoveFromServer: Set<String> = []
    /// Human-readable reason when a plausibility guard fired (nil = clean run).
    var warning: String?
    /// False when the guard fired: the last-synced state must stay untouched,
    /// otherwise the surviving feeds would be pushed to the server as "newly
    /// subscribed" on the next run and the incident would be papered over.
    var mayUpdatePrevState: Bool = true

    /// A remove batch is implausible when it exceeds BOTH a small absolute
    /// count and a relative share of the affected side. A single unsubscribe
    /// (the everyday case) always passes.
    static func removesImplausible(count: Int, of total: Int) -> Bool {
        guard count > 1 else { return false }
        return count > 3 || Double(count) / Double(max(total, 1)) > 0.3
    }

    /// Confirmation for the 2–3-feed edge case: a SINGLE removal applies at once
    /// (the everyday unsubscribe, unchanged); 2–3 feeds must have been pending
    /// from the PREVIOUS run (`prevPending`) to apply now — a first-time 2–3 diff
    /// is only held (returned as pending), so a one-off race/glitch self-heals
    /// next run instead of removing anything. Pure/tested.
    static func confirmRemovals(candidates: Set<String>, prevPending: Set<String>)
        -> (apply: Set<String>, pending: Set<String>) {
        if candidates.count <= 1 { return (candidates, []) }   // single: immediate
        let apply = candidates.intersection(prevPending)       // seen last run → confirmed
        return (apply, candidates.subtracting(apply))          // newcomers wait one cycle
    }

    static func compute(local: Set<String>, server: Set<String>, prev: Set<String>,
                        pendingRemoveLocally prevPendingLocal: Set<String> = [],
                        pendingRemoveFromServer prevPendingServer: Set<String> = [])
        -> GPodderSubscriptionMerge {
        var merge = GPodderSubscriptionMerge()

        // Empty server answer while we clearly had a synced state: treat the
        // whole answer as suspect and change NOTHING on either side.
        if server.isEmpty, !local.isEmpty, !prev.isEmpty {
            merge.warning = "gpodder returned an empty subscription list — sync skipped to protect \(local.count) local feeds."
            merge.mayUpdatePrevState = false
            return merge
        }

        merge.addToServer = local.subtracting(server).subtracting(prev)
        merge.addLocally = server.subtracting(local).subtracting(prev)
        let removeFromServer = prev.intersection(server).subtracting(local)
        let removeLocally = prev.intersection(local).subtracting(server)

        // Local side: guard (>3/>30%) unchanged; else 2–3 need confirmation.
        if removesImplausible(count: removeLocally.count, of: local.count) {
            merge.warning = "gpodder answer would unsubscribe \(removeLocally.count) of \(local.count) local feeds — skipped as implausible."
            merge.mayUpdatePrevState = false
            merge.blockedRemoveLocally = removeLocally
        } else {
            let c = confirmRemovals(candidates: removeLocally, prevPending: prevPendingLocal)
            merge.removeLocally = c.apply
            merge.pendingRemoveLocally = c.pending
            if !c.pending.isEmpty { merge.mayUpdatePrevState = false }
        }
        // Server side: same shape.
        if removesImplausible(count: removeFromServer.count, of: server.count) {
            let text = "local state would unsubscribe \(removeFromServer.count) of \(server.count) server feeds — skipped as implausible."
            merge.warning = merge.warning.map { $0 + " " + text } ?? "gpodder: " + text
            merge.mayUpdatePrevState = false
            merge.blockedRemoveFromServer = removeFromServer
        } else {
            let c = confirmRemovals(candidates: removeFromServer, prevPending: prevPendingServer)
            merge.removeFromServer = c.apply
            merge.pendingRemoveFromServer = c.pending
            if !c.pending.isEmpty { merge.mayUpdatePrevState = false }
        }
        return merge
    }
}
