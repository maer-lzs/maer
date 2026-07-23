// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

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

        // Local dropped one feed → propagates to the server.
        var local = feeds; local.remove("feed3")
        let m2 = GPodderSubscriptionMerge.compute(local: local, server: feeds, prev: feeds)
        #expect(m2.removeFromServer == ["feed3"])
        #expect(m2.warning == nil)
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
        // Two of five synced feeds vanish at once — above the relative
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
}
#endif
