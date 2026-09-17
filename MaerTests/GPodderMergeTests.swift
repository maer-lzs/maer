// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Mass-delete guard of the gpodder subscription merge: implausible server
/// answers must not unsubscribe local feeds, while everyday single
/// unsubscribes keep propagating.
struct GPodderMergeTests {
    let feeds = Set((1...20).map { "feed\($0)" })

    @Test func emptyServerAnswerChangesNothing() {
        let m = GPodderSubscriptionMerge.compute(local: feeds, server: [], prev: feeds)
        #expect(m.removeLocally.isEmpty)
        #expect(m.removeFromServer.isEmpty)
        #expect(m.addToServer.isEmpty)
        #expect(m.addLocally.isEmpty)
        #expect(m.warning != nil)
        #expect(!m.mayUpdatePrevState)
    }

    @Test func halvedServerListVetoesLocalRemoves() {
        let server = Set(feeds.prefix(10))
        let m = GPodderSubscriptionMerge.compute(local: feeds, server: server, prev: feeds)
        #expect(m.removeLocally.isEmpty)
        #expect(m.warning != nil)
        #expect(!m.mayUpdatePrevState)
    }

    @Test func singleUnsubscribeStillPropagates() {
        // Server dropped exactly one previously synced feed → legitimate.
        var server = feeds; server.remove("feed7")
        let m = GPodderSubscriptionMerge.compute(local: feeds, server: server, prev: feeds)
        #expect(m.removeLocally == ["feed7"])
        #expect(m.warning == nil)
        #expect(m.mayUpdatePrevState)

        // A local drop WITHOUT user intent no longer touches
        // the server at once. It pends (the derived-single loss class).
        var local = feeds; local.remove("feed3")
        let derived = GPodderSubscriptionMerge.compute(local: local, server: feeds, prev: feeds)
        #expect(derived.removeFromServer.isEmpty)
        #expect(derived.pendingRemoveFromServer == ["feed3"])
        // With USER intent (UI unsubscribe) it propagates immediately.
        let m2 = GPodderSubscriptionMerge.compute(local: local, server: feeds, prev: feeds,
                                                  userRemovedLocally: ["feed3"])
        #expect(m2.removeFromServer == ["feed3"])
        #expect(m2.warning == nil)
    }

    /// The loop the family could open on a device with a server: the
    /// family removes a feed here (user intent, made elsewhere), the push
    /// takes it off the server, and the pull after that must not bring it
    /// back; a feed the family adds here goes to the server.
    @Test("Familie und Server sagen dasselbe: der Pull bringt ein abbestelltes Abo nicht zurueck, ein neues geht zum Server")
    func theFamilyAndTheServerSayTheSame() {
        let feed = "https://example.org/f.xml", other = "https://example.org/g.xml"
        // (b) removed here by the family, still on the server, in prev.
        let push = GPodderSubscriptionMerge.compute(local: [], server: [feed], prev: [feed],
                                                    userRemovedLocally: [feed])
        #expect(push.removeFromServer == [feed], "the family's unsubscribe reaches the server at once")
        #expect(push.addLocally.isEmpty, "the server copy is not read as new")
        // The pull afterwards, before AND after prev caught up: nothing returns.
        #expect(GPodderSubscriptionMerge.compute(local: [], server: [], prev: [feed]).addLocally.isEmpty)
        #expect(GPodderSubscriptionMerge.compute(local: [], server: [], prev: []).addLocally.isEmpty)
        // (c) added here by the family: to the server.
        let add = GPodderSubscriptionMerge.compute(local: [other], server: [], prev: [])
        #expect(add.addToServer == [other])
        #expect(add.removeLocally.isEmpty)
    }

    @Test func massLocalWipeDoesNotUnsubscribeServer() {
        // Local list lost (fresh install with stale prev state): the server
        // side must keep its feeds.
        let m = GPodderSubscriptionMerge.compute(local: ["feed1"], server: feeds, prev: feeds)
        #expect(m.removeFromServer.isEmpty)
        #expect(m.warning != nil)
        #expect(!m.mayUpdatePrevState)
    }

    @Test func firstRunUnionStaysNonDestructive() {
        let local: Set<String> = ["a", "b"]
        let server: Set<String> = ["c"]
        let m = GPodderSubscriptionMerge.compute(local: local, server: server, prev: [])
        #expect(m.addToServer == ["a", "b"])
        #expect(m.addLocally == ["c"])
        #expect(m.removeLocally.isEmpty && m.removeFromServer.isEmpty)
        #expect(m.warning == nil)
    }

    @Test func smallListDoubleUnsubscribeIsVetoed() {
        // Two of five synced feeds vanish at once. Above the relative
        // threshold, below the absolute one: still vetoed (count > 1).
        let five = Set(["a", "b", "c", "d", "e"])
        var server = five; server.remove("a"); server.remove("b")
        let m = GPodderSubscriptionMerge.compute(local: five, server: server, prev: five)
        #expect(m.removeLocally.isEmpty)
        #expect(m.warning != nil)
    }

    // Log-First: a vetoed removal must still be VISIBLE via the blocked-candidate
    // sets (for the diagnostic log), while an applied removal is not "blocked".
    @Test func vetoedRemovesAreExposedAsBlockedCandidates() {
        let five = Set(["a", "b", "c", "d", "e"])
        var server = five; server.remove("a"); server.remove("b")
        let m = GPodderSubscriptionMerge.compute(local: five, server: server, prev: five)
        #expect(m.removeLocally.isEmpty)                 // not applied
        #expect(m.blockedRemoveLocally == ["a", "b"])    // but recorded for the log
        #expect(m.blockedRemoveFromServer.isEmpty)
    }

    @Test func appliedSingleRemoveIsNotBlocked() {
        var server = feeds; server.remove("feed7")
        let m = GPodderSubscriptionMerge.compute(local: feeds, server: server, prev: feeds)
        #expect(m.removeLocally == ["feed7"])
        #expect(m.blockedRemoveLocally.isEmpty)
        #expect(m.blockedRemoveFromServer.isEmpty)
    }

    // MARK: - 2–3-feed confirmation (hardening: apply only after a 2nd sync)

    @Test func singleRemoveStaysImmediate() {
        let (apply, pending) = GPodderSubscriptionMerge.confirmRemovals(candidates: ["a"], prevPending: [])
        #expect(apply == ["a"])
        #expect(pending.isEmpty)
    }

    @Test func twoFeedRemovalFirstRunOnlyPends() {
        // Six local feeds, server dropped two → 2/6 = 33% is > 30%? 0.333 > 0.3 →
        // that WOULD be guard-blocked. Use eight feeds so 2/8 = 25% stays under
        // the guard and reaches the confirmation path.
        let eight = Set((1...8).map { "f\($0)" })
        var server = eight; server.remove("f1"); server.remove("f2")
        let m = GPodderSubscriptionMerge.compute(local: eight, server: server, prev: eight,
                                                 pendingRemoveLocally: [], pendingRemoveFromServer: [])
        #expect(m.warning == nil)                         // under the guard
        #expect(m.removeLocally.isEmpty)                  // NOT applied on first sight
        #expect(m.pendingRemoveLocally == ["f1", "f2"])   // held for confirmation
        #expect(!m.mayUpdatePrevState)                    // prev kept so it recomputes
    }

    @Test func twoFeedRemovalSecondRunApplies() {
        let eight = Set((1...8).map { "f\($0)" })
        var server = eight; server.remove("f1"); server.remove("f2")
        // Same diff still stands, and both were pending from last run → apply.
        let m = GPodderSubscriptionMerge.compute(local: eight, server: server, prev: eight,
                                                 pendingRemoveLocally: ["f1", "f2"], pendingRemoveFromServer: [])
        #expect(m.removeLocally == ["f1", "f2"])
        #expect(m.pendingRemoveLocally.isEmpty)
    }

    @Test func glitchedRemovalSelfHeals() {
        // First run pended {f1,f2}; next run the feeds are back (no candidate) →
        // nothing applied and the pending set clears.
        let eight = Set((1...8).map { "f\($0)" })
        let m = GPodderSubscriptionMerge.compute(local: eight, server: eight, prev: eight,
                                                 pendingRemoveLocally: ["f1", "f2"], pendingRemoveFromServer: [])
        #expect(m.removeLocally.isEmpty)
        #expect(m.pendingRemoveLocally.isEmpty)           // discarded, self-healed
        #expect(m.mayUpdatePrevState)
    }

    @Test("593d177 R1: loss signature adopts the server wholesale — pull only")
    func lossSignatureRecovery() {
        let server: Set<String> = Set((1...44).map { "feed\($0)" })
        let merge = GPodderSubscriptionMerge.compute(local: [], server: server, prev: server)
        #expect(merge.recoveredFromServer)
        #expect(merge.addLocally == server)
        // Pull ONLY: nothing pushed, nothing deleted, nowhere.
        #expect(merge.addToServer.isEmpty)
        #expect(merge.removeFromServer.isEmpty)
        #expect(merge.removeLocally.isEmpty)
        #expect(merge.pendingRemoveFromServer.isEmpty)
        // A genuine fresh state (prev empty too) is NOT the signature.
        let fresh = GPodderSubscriptionMerge.compute(local: [], server: server, prev: [])
        #expect(!fresh.recoveredFromServer)
    }

    @Test("486b293: R1 respects user intents — the last unsubscribe is never resurrected")
    func recoveryRespectsIntent() {
        // Last-feed unsubscribe: emptiness fully user-explained → NO recovery,
        // the intent remove propagates instead (and only once).
        let one = GPodderSubscriptionMerge.compute(
            local: [], server: ["feedX"], prev: ["feedX"], userRemovedLocally: ["feedX"])
        #expect(!one.recoveredFromServer)
        #expect(one.addLocally.isEmpty)
        #expect(one.removeFromServer == ["feedX"])
        // Mixed: 44 on the server, 2 user-removed → recover the 42, push the 2.
        let server = Set((1...44).map { "f\($0)" })
        let mixed = GPodderSubscriptionMerge.compute(
            local: [], server: server, prev: server, userRemovedLocally: ["f1", "f2"])
        #expect(mixed.recoveredFromServer)
        #expect(mixed.addLocally == server.subtracting(["f1", "f2"]))
        #expect(mixed.removeFromServer == ["f1", "f2"])
        // Mass user unsubscribe (5 of 5, all intended): the implausibility
        // guard never blocks a decision.
        let five = Set((1...5).map { "g\($0)" })
        let all = GPodderSubscriptionMerge.compute(
            local: [], server: five, prev: five, userRemovedLocally: five)
        #expect(!all.recoveredFromServer)
        #expect(all.removeFromServer == five)
        #expect(all.warning == nil)
    }

    @Test("593d177 R2: derived single removes wait for the second sync; user intent applies at once")
    func derivedSinglesPend() {
        // SERVER side: a derived single (state diff, no user intent) PENDS.
        let derived = GPodderSubscriptionMerge.confirmRemovals(
            candidates: ["feedX"], prevPending: [], userIntent: [],
            requireIntentForSingles: true)
        #expect(derived.apply.isEmpty)
        #expect(derived.pending == ["feedX"])
        // Same single with USER intent: immediate.
        let intended = GPodderSubscriptionMerge.confirmRemovals(
            candidates: ["feedX"], prevPending: [], userIntent: ["feedX"],
            requireIntentForSingles: true)
        #expect(intended.apply == ["feedX"])
        #expect(intended.pending.isEmpty)
        // Second consecutive sync confirms a derived server remove.
        let confirmed = GPodderSubscriptionMerge.confirmRemovals(
            candidates: ["feedX"], prevPending: ["feedX"], userIntent: [],
            requireIntentForSingles: true)
        #expect(confirmed.apply == ["feedX"])
        // LOCAL side unchanged: a single server-side removal converges at once.
        let localSingle = GPodderSubscriptionMerge.confirmRemovals(
            candidates: ["feedX"], prevPending: [])
        #expect(localSingle.apply == ["feedX"])
    }

    @Test("593d177: wipe guard — an empty snapshot never overwrites data")
    @MainActor
    func wipeGuard() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        let show = PodcastShow(id: "wipe-test", title: "Wipe Test", author: nil,
                               artworkURL: nil, description: nil,
                               feedURL: "https://example.org/wipe.xml", episodes: [])
        subs._testSetLoaded(true)
        subs._testPersist([show])
        // The write chain is async: wait for it. (Behavioral assertions, not
        // row equality: Swift Testing runs in-process parallel and other
        // suites touch the shared singleton.)
        await subs.awaitPendingWrites()
        let landed = await subs._testRowCounts()
        #expect((landed?.shows ?? 0) > 0, "seed state must land in the rows first")
        // The EMPTY snapshot without user intent must be REFUSED: the rows
        // keep holding a NON-empty stock and the tombstone note appears
        // (log-first diagnosis).
        subs._testPersist([])
        await subs.awaitPendingWrites()
        let kept = await subs._testRowCounts()
        #expect((kept?.shows ?? 0) > 0, "empty snapshot must never wipe a non-empty store")
        let tombstone = subs._testFileURL.appendingPathExtension("wipe-refused.txt")
        #expect(FileManager.default.fileExists(atPath: tombstone.path),
                "the refused wipe must leave a diagnosable tombstone")
    }
}
#endif