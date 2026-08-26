// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import ABSPlayer

/// "Not in memory" must not mean "does not exist".
///
/// Three device findings, one mistake: playlist rows went dead raw-id lines,
/// the queue went visually empty and the advancer ended silently. All three
/// asked the session cache, which answers catalogue ids only from session
/// memory. A catalogue id is self-describing and resolves on demand.
struct PlayableItemTests {
    @MainActor
    @Test("a catalogue id answers a playable item after a cold start")
    func catalogIdsResolveOnDemand() {
        // Nothing was fetched this session. The cache is empty for these.
        let song = AppSession.shared.playableItem(forId: "lva:coldstart-album#3")
        #expect(song?.id == "lva:coldstart-album#3")
        let album = AppSession.shared.playableItem(forId: "lva:coldstart-album")
        #expect(album != nil)
        let book = AppSession.shared.playableItem(forId: "lv:12345")
        #expect(book != nil)
    }

    @MainActor
    @Test("other namespaces keep the cache answer — absent stays absent")
    func otherNamespacesStayAuthoritative() {
        // A server title without its server really is unavailable here; a
        // fabricated stub would promise a playback that cannot start.
        #expect(AppSession.shared.playableItem(forId: "sub:never-seen") == nil)
        #expect(AppSession.shared.playableItem(forId: "jf:never-seen") == nil)
        #expect(AppSession.shared.playableItem(forId: "radio:never-seen") == nil)
        #expect(AppSession.shared.playableItem(forId: "weird:namespace") == nil)
    }

    /// The advancer's decision with on-demand resolution: a queue holding only
    /// a cold catalogue id no longer ends silently before it.
    @Test("the queue advancer reaches a cold catalogue entry")
    func advancerReachesColdCatalogEntry() {
        let ids = ["sub:gone", "lva:cold#2"]
        let next = QueueContinuation.nextPlayable(
            ids: ids,
            isPlayable: { _ in true },
            resolves: { id in id.hasPrefix("lva:") })   // the cache miss, the stub answer
        #expect(next == "lva:cold#2")
    }
}
