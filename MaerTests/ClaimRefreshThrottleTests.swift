// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A foreign claim on a library item triggers one progress refresh, then
/// at most one per minute per item; heartbeats in between trigger nothing.
struct ClaimRefreshThrottleTests {
    @Test("Der erste Anspruch je Item loest aus, Herzschlaege darunter nicht, nach 60 s wieder")
    func onePerItemThenEverySixtySeconds() {
        var gate = ClaimRefreshThrottle(intervalMs: 60_000)
        let first = gate.admits(itemId: "book-1", nowMs: 1_000)
        let beat = gate.admits(itemId: "book-1", nowMs: 11_000)
        let justBefore = gate.admits(itemId: "book-1", nowMs: 60_999)
        let afterMinute = gate.admits(itemId: "book-1", nowMs: 61_000)
        let other = gate.admits(itemId: "abspod:ep-2", nowMs: 61_500)
        #expect(first)
        #expect(!beat, "the next heartbeat ten seconds later")
        #expect(!justBefore)
        #expect(afterMinute)
        #expect(other, "another item is its own gate")
    }

    @Test("Nur Bibliotheks-Items mit Server-Stand loesen einen Refresh aus")
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
