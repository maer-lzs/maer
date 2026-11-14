// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A foreign claim on a library item triggers one progress refresh, a
/// second pass fifteen seconds later on the next heartbeat (the other
/// device's push may land after the first), then at most one per minute
/// per item; heartbeats in between trigger nothing.
struct ClaimRefreshThrottleTests {
    @Test("First pass at once, second at the first heartbeat after 15 s, then every 60 s")
    func firstThenSecondThenEveryMinute() {
        var gate = ClaimRefreshThrottle(intervalMs: 60_000, secondPassMs: 15_000)
        let first = gate.admittedPass(itemId: "book-1", nowMs: 1_000)
        let beat = gate.admittedPass(itemId: "book-1", nowMs: 11_000)
        let second = gate.admittedPass(itemId: "book-1", nowMs: 21_000)
        let beatAfterSecond = gate.admittedPass(itemId: "book-1", nowMs: 31_000)
        let justBefore = gate.admittedPass(itemId: "book-1", nowMs: 80_999)
        let afterMinute = gate.admittedPass(itemId: "book-1", nowMs: 81_000)
        let noThirdSecondPass = gate.admittedPass(itemId: "book-1", nowMs: 96_000)
        let other = gate.admittedPass(itemId: "abspod:ep-2", nowMs: 81_500)
        #expect(first == 1)
        #expect(beat == nil, "the next heartbeat ten seconds later")
        #expect(second == 2, "the heartbeat after fifteen seconds runs the second pass")
        #expect(beatAfterSecond == nil)
        #expect(justBefore == nil, "the minute counts from the second pass")
        #expect(afterMinute == 3)
        #expect(noThirdSecondPass == nil, "the second pass is owed once per item")
        #expect(other == 1, "another item is its own gate")
    }

    @Test("If the heartbeats stop, the second pass runs at the next claim")
    func secondPassWaitsForTheNextClaim() {
        var gate = ClaimRefreshThrottle(intervalMs: 60_000, secondPassMs: 15_000)
        let first = gate.admittedPass(itemId: "book-1", nowMs: 1_000)
        let muchLater = gate.admittedPass(itemId: "book-1", nowMs: 3_600_000)
        #expect(first == 1)
        #expect(muchLater == 2)
    }

    @Test("Only library items with a server state trigger a refresh")
    func onlyLibraryItemsRefresh() {
        #expect(ClaimRefreshThrottle.library(of: "5f3a-abs-book") == .books)
        #expect(ClaimRefreshThrottle.library(of: "abspod:ep-9") == .serverPodcasts)
        #expect(ClaimRefreshThrottle.library(of: "rss:feed:guid") == nil, "the pot carries it")
        #expect(ClaimRefreshThrottle.library(of: "lv:123") == nil)
        #expect(ClaimRefreshThrottle.library(of: "local:file") == nil)
        #expect(ClaimRefreshThrottle.library(of: "sub:album:1") == nil, "server music travels by the claim alone")
        #expect(ClaimRefreshThrottle.library(of: "radio:rb:x") == nil)
    }
}
#endif
