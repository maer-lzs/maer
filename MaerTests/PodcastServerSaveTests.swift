// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The re-key after a server save: the stand of the feed episode moves onto
/// the server episode, and the server gets only the stand that won. A newer
/// stand of the server-side twin is neither painted over locally nor on the
/// server.
@MainActor
struct PodcastServerSaveTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "server-save-\(UUID().uuidString)")!
    }

    @Test("if the server episode holds a newer state, it stays local and no older one goes to the server")
    func aNewerTwinIsNotPaintedOver() {
        let d = suite()
        ListeningStore.record("rss:save:e1", position: 30, duration: 1800, atMs: 1_000, in: d)
        ListeningStore.record("abspod:save:e1", position: 900, duration: 1800, atMs: 9_000, in: d)
        let pushed = PodcastServerSave.moveStand(from: "rss:save:e1", to: "abspod:save:e1", in: d)
        let kept = ListeningStore.position("abspod:save:e1", in: d)
        #expect(kept == 900, "the newer stand of the twin was painted over locally: \(String(describing: kept))")
        #expect(pushed == nil, "the older stand goes to the server over the newer one: \(String(describing: pushed))")
        #expect(ListeningStore.backup("rss:save:e1", in: d) == nil, "the feed episode keeps a stand")
    }

    @Test("if the state of the feed episode is newer or the target empty, it goes over and to the server")
    func theWinningStandGoesToTheServer() {
        let d = suite()
        ListeningStore.record("rss:save:e2", position: 300, duration: 1800, atMs: 9_000, in: d)
        ListeningStore.record("abspod:save:e2", position: 100, duration: 1800, atMs: 1_000, in: d)
        let newer = PodcastServerSave.moveStand(from: "rss:save:e2", to: "abspod:save:e2", in: d)
        #expect(newer?.first == 300, "the newer arriving stand did not go to the server: \(String(describing: newer))")
        #expect(ListeningStore.position("abspod:save:e2", in: d) == 300)

        ListeningStore.record("rss:save:e3", position: 42, duration: 1800, atMs: 2_000, in: d)
        let alone = PodcastServerSave.moveStand(from: "rss:save:e3", to: "abspod:save:e3", in: d)
        #expect(alone?.first == 42, "onto an empty target nothing went to the server: \(String(describing: alone))")
        #expect(PodcastServerSave.moveStand(from: "rss:save:none", to: "abspod:save:none", in: d) == nil,
                "a feed episode without a stand pushed something")
    }
}
#endif
