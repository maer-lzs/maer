// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Teil 1 (global Up-Next): the queue holds ids of ALL media types, dedups by
/// podcast twin (rss:/abspod:) and enforces "heard = flies out" via
/// markedPlayed.
@MainActor
struct PlayQueueTests {

    /// Fresh, non-persisting queue with an optional twin map.
    private func queue(twins: [String: [String]] = [:]) -> PlayQueue {
        PlayQueue(persists: false, equivalents: { twins[$0] ?? [$0] })
    }

    @Test("playNext / playLast keep order and never duplicate")
    func orderAndDedup() {
        let q = queue()
        q.playLast("a"); q.playLast("b"); q.playNext("c")
        #expect(q.ids == ["c", "a", "b"])
        q.playNext("a")                       // pull existing to the front
        #expect(q.ids == ["a", "c", "b"])
        q.playLast("a")                        // already present → no-op
        #expect(q.ids == ["a", "c", "b"])
    }

    @Test("remove and markedPlayed drop the entry (invariant c)")
    func removeAndMarkedPlayed() {
        let q = queue()
        ["a", "b", "c"].forEach { q.playLast($0) }
        q.markedPlayed("b")
        #expect(q.ids == ["a", "c"])
        q.remove("a")
        #expect(q.ids == ["c"])
        q.remove("zzz")                        // absent → no-op
        #expect(q.ids == ["c"])
    }

    @Test("removal is equivalence-aware: a twin id takes out both faces")
    func equivalenceAwareRemove() {
        let twins = ["rss:1": ["rss:1", "abspod:1"], "abspod:1": ["rss:1", "abspod:1"]]
        let q = queue(twins: twins)
        q.playLast("abspod:1"); q.playLast("a")
        #expect(q.contains("rss:1"))           // queued under its twin
        q.markedPlayed("rss:1")                // mark via the OTHER face
        #expect(q.ids == ["a"])
        // playLast must not re-add a twin already present.
        q.playLast("abspod:1")
        q.playLast("rss:1")
        #expect(q.ids.filter { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") }.count == 1)
    }

    @Test("move reorders")
    func move() {
        let q = queue()
        ["a", "b", "c"].forEach { q.playLast($0) }
        q.move(from: IndexSet(integer: 0), to: 3)   // a to the end
        #expect(q.ids == ["b", "c", "a"])
    }

    @Test("clear empties the queue")
    func clear() {
        let q = queue()
        ["a", "b"].forEach { q.playLast($0) }
        q.clear()
        #expect(q.isEmpty)
    }

    // MOVED: `setUpNext` wrote the collection remainder into THE queue and
    // thereby threw away the hand orders. The remainder is now CONTEXT
    // (own structure, own lifetime); the replace semantics including the
    // radio filter live on there, and the orders survive every
    // collection start.
    @Test("a collection start replaces the context and lets the orders live")
    func collectionStartSparesTheOrders() throws {
        let q = queue()
        ["bestellt1", "bestellt2"].forEach { q.playLast($0) }
        let context = PlaybackContext()
        context.replace(ids: ["s1", "s2", "radio:x", "s3"], source: "Album A")
        // Red probe against yesterday's actual state: the orders
        // would have been overwritten by setUpNext.
        #expect(q.ids == ["bestellt1", "bestellt2"],
                "der Sammlungs-Start hat die Bestellungen angefasst")
        #expect(context.ids == ["s1", "s2", "s3"], "Radio faehrt nie mit")
        #expect(context.sourceTitle == "Album A")
        // Next start replaces; single start deletes; source falls
        // with the last entry.
        context.replace(ids: ["t1"], source: "Album B")
        #expect(context.ids == ["t1"] && context.sourceTitle == "Album B")
        context.remove("t1")
        #expect(context.isEmpty && context.sourceTitle == nil)
        context.replace(ids: ["u1"], source: "C")
        context.clear()
        #expect(context.isEmpty && context.sourceTitle == nil)
    }

    /// The case, verbatim, at the pure cascade: music shuffle is running
    /// (context full), a podcast is tapped (context dies, which is
    /// checked by the coordinator path; here stands the rule after it), the episode
    /// ends: NEXT EPISODE (stage 3 of the caller), never the old music.
    /// And: an order beats both, across media.
    @Test("order before context before continuation, and a dead context never wins")
    func advanceOrderIsOrdersThenContext() {
        // Order AND context present: the order wins.
        var hit = PlaybackAdvance.next(queueIds: ["rss:bestellt"],
                                       contextIds: ["sub:song:alt1"],
                                       isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit?.id == "rss:bestellt" && hit?.origin == .order)
        // Only context: the context.
        hit = PlaybackAdvance.next(queueIds: [],
                                   contextIds: ["sub:song:alt1", "sub:song:alt2"],
                                   isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit?.id == "sub:song:alt1" && hit?.origin == .context)
        // The case: context is emptied (the podcast tap killed
        // it), no order: the cascade answers NOTHING, and
        // the caller goes into the medium's own continuation (binge).
        hit = PlaybackAdvance.next(queueIds: [], contextIds: [],
                                   isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit == nil, "die alte Musik haette gewonnen")
        // Unplayable context does not block the answer.
        hit = PlaybackAdvance.next(queueIds: [], contextIds: ["tot", "sub:song:ok"],
                                   isPlayable: { $0 != "tot" }, resolves: { _ in true })
        #expect(hit?.id == "sub:song:ok")
    }

    /// The assignment case VERBATIM at the whole cascade: hours ago
    /// music shuffle started, then a podcast was tapped (the tap kills
    /// the music context), the episode ends: the NEXT EPISODE plays,
    /// never the old music. The red probe next to it shows that exactly the
    /// killing carries the case: with a surviving context the music would have
    /// won.
    @Test("shuffle, then podcast, then end: the next episode plays, never the old music")
    func theReportedCaseVerbatim() {
        func aufloesen(kontext: [String]) -> (id: String, origin: PlaybackAdvance.Origin)? {
            PlaybackAdvance.resolveNext(
                after: "rss:folge1",
                queueIds: [], contextIds: kontext,
                isPlayable: { _ in true }, resolves: { _ in true },
                isPodcast: { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") },
                bingeNext: { _ in "rss:folge2" },
                seriesEnabled: false, seriesNext: { _ in nil })
        }
        // The tap killed the context: the next episode plays.
        let hit = aufloesen(kontext: [])
        #expect(hit?.id == "rss:folge2" && hit?.origin == .binge)
        // Red probe: had the context survived, the old music would win
        // (the actual state before the rebuild, when the collection remainder lay in the
        // queue and stage 1 won).
        let alt = aufloesen(kontext: ["sub:song:altemusik"])
        #expect(alt?.id == "sub:song:altemusik",
                "die Probe saehe den Unterschied nicht")
        // And: an ORDER beats the binge (the evening plan holds).
        let bestellt = PlaybackAdvance.resolveNext(
            after: "rss:folge1", queueIds: ["book:krimi"], contextIds: [],
            isPlayable: { _ in true }, resolves: { _ in true },
            isPodcast: { _ in true }, bingeNext: { _ in "rss:folge2" },
            seriesEnabled: false, seriesNext: { _ in nil })
        #expect(bestellt?.id == "book:krimi" && bestellt?.origin == .order)
        // Books: the series answers only with the default switched on,
        // and podcasts NEVER fall through into the series stage.
        let serieAus = PlaybackAdvance.resolveNext(
            after: "buch1", queueIds: [], contextIds: [],
            isPlayable: { _ in true }, resolves: { _ in true },
            isPodcast: { _ in false }, bingeNext: { _ in nil },
            seriesEnabled: false, seriesNext: { _ in "buch2" })
        #expect(serieAus == nil, "die Serie spielte gegen die Vorgabe")
        let podcastOhneBinge = PlaybackAdvance.resolveNext(
            after: "rss:folge1", queueIds: [], contextIds: [],
            isPlayable: { _ in true }, resolves: { _ in true },
            isPodcast: { $0.hasPrefix("rss:") }, bingeNext: { _ in nil },
            seriesEnabled: true, seriesNext: { _ in "buch2" })
        #expect(podcastOhneBinge == nil, "ein Podcast fiel in die Serien-Stufe durch")
    }

    // MARK: - Cross-media auto-continue (Part 1 core journey)

    /// Proves the core journey "enqueue mixed types → auto-continue across the
    /// media boundary" deterministically: a book, an album and an episode share
    /// one queue; continuation scans in order, honours the offline filter and
    /// skips orphans. Crossing type boundaries as the queue dictates.
    @Test("cross-media continuation picks the first playable across type boundaries")
    func crossMediaContinuation() {
        let ids = ["book1", "sub:album:2", "rss:3", "book4"]
        // Online, everything resolves → the very first entry (a book).
        #expect(QueueContinuation.nextPlayable(ids: ids, isPlayable: { _ in true },
                                               resolves: { _ in true }) == "book1")
        // Offline, only the music album is downloaded → skip the book, cross the
        // boundary to music.
        #expect(QueueContinuation.nextPlayable(ids: ids, isPlayable: { $0 == "sub:album:2" },
                                               resolves: { _ in true }) == "sub:album:2")
        // The first entry no longer resolves (removed from library) → skip it.
        #expect(QueueContinuation.nextPlayable(ids: ids, isPlayable: { _ in true },
                                               resolves: { $0 != "book1" }) == "sub:album:2")
        // Nothing playable (offline, none downloaded) → nil, player stays put.
        #expect(QueueContinuation.nextPlayable(ids: ids, isPlayable: { _ in false },
                                               resolves: { _ in true }) == nil)
    }
}
#endif
