// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Teil 1 (global Up-Next): the queue holds ids of ALL media types, dedups by
/// podcast twin (rss:/abspod:), enforces "heard = flies out" via markedPlayed,
/// and migrates the former podcast-only queue file once.
@MainActor
struct PlayQueueTests {

    /// Fresh, non-persisting queue with an optional twin map.
    private func queue(twins: [String: [String]] = [:]) -> PlayQueue {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pq-\(UUID().uuidString).json")
        return PlayQueue(fileURL: tmp, persists: false,
                         equivalents: { twins[$0] ?? [$0] })
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

    @Test("one-time migration adopts the former podcast-only queue file")
    func migration() throws {
        let dir = FileManager.default.temporaryDirectory
        let legacy = dir.appendingPathComponent("legacy-\(UUID().uuidString).json")
        let current = dir.appendingPathComponent("current-\(UUID().uuidString).json")
        try JSONEncoder().encode(["rss:x", "abspod:y"]).write(to: legacy)
        // New file absent → adopt legacy, persist, delete legacy.
        let q = PlayQueue(fileURL: current, migrateFrom: legacy, persists: true)
        #expect(q.ids == ["rss:x", "abspod:y"])
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // A second instance now loads the migrated file directly.
        let q2 = PlayQueue(fileURL: current, migrateFrom: legacy, persists: true)
        #expect(q2.ids == ["rss:x", "abspod:y"])
        try? FileManager.default.removeItem(at: current)
    }

    @Test("clear empties the queue")
    func clear() {
        let q = queue()
        ["a", "b"].forEach { q.playLast($0) }
        q.clear()
        #expect(q.isEmpty)
    }

    // GEWANDERT: `setUpNext` schrieb den Sammlungs-Rest in DIE Queue und
    // warf damit die Hand-Bestellungen weg. Der Rest ist jetzt KONTEXT
    // (eigene Struktur, eigene Lebensdauer); die Ersetzen-Semantik samt
    // Radio-Filter lebt dort weiter, und die Bestellungen ueberleben jeden
    // Sammlungs-Start.
    @Test("ein Sammlungs-Start ersetzt den Kontext und laesst die Bestellungen leben")
    func collectionStartSparesTheOrders() throws {
        let q = queue()
        ["bestellt1", "bestellt2"].forEach { q.playLast($0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-\(UUID().uuidString).json")
        let context = PlaybackContext(fileURL: dir)
        context.replace(ids: ["s1", "s2", "radio:x", "s3"], source: "Album A")
        // Rot-Probe gegen den Ist-Zustand von gestern: die Bestellungen
        // waeren mit setUpNext ueberschrieben worden.
        #expect(q.ids == ["bestellt1", "bestellt2"],
                "der Sammlungs-Start hat die Bestellungen angefasst")
        #expect(context.ids == ["s1", "s2", "s3"], "Radio faehrt nie mit")
        #expect(context.sourceTitle == "Album A")
        // Naechster Start ersetzt; einzelner Start loescht; Quelle faellt
        // mit dem letzten Eintrag.
        context.replace(ids: ["t1"], source: "Album B")
        #expect(context.ids == ["t1"] && context.sourceTitle == "Album B")
        context.remove("t1")
        #expect(context.isEmpty && context.sourceTitle == nil)
        context.replace(ids: ["u1"], source: "C")
        context.clear()
        #expect(context.isEmpty && context.sourceTitle == nil)
    }

    /// the owner's Fall, woertlich, an der puren Kaskade: Musik-Zufall laeuft
    /// (Kontext voll), ein Podcast wird angetippt (Kontext stirbt — das
    /// prueft der Koordinator-Pfad; hier steht die Regel danach), die Folge
    /// endet: NAECHSTE FOLGE (Stufe 3 des Aufrufers), nie die alte Musik.
    /// Und: eine Bestellung schlaegt beides, medienuebergreifend.
    @Test("Bestellung vor Kontext vor Fortsetzung, und toter Kontext gewinnt nie")
    func advanceOrderIsOrdersThenContext() {
        // Bestellung UND Kontext da: die Bestellung gewinnt.
        var hit = PlaybackAdvance.next(queueIds: ["rss:bestellt"],
                                       contextIds: ["sub:song:alt1"],
                                       isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit?.id == "rss:bestellt" && hit?.origin == .order)
        // Nur Kontext: der Kontext.
        hit = PlaybackAdvance.next(queueIds: [],
                                   contextIds: ["sub:song:alt1", "sub:song:alt2"],
                                   isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit?.id == "sub:song:alt1" && hit?.origin == .context)
        // the owner's Fall: Kontext ist geleert (der Podcast-Tipp hat ihn
        // getoetet), keine Bestellung — die Kaskade antwortet NICHTS, und
        // der Aufrufer geht in die medium-eigene Fortsetzung (Binge).
        hit = PlaybackAdvance.next(queueIds: [], contextIds: [],
                                   isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit == nil, "die alte Musik haette gewonnen")
        // Unspielbarer Kontext blockiert die Antwort nicht.
        hit = PlaybackAdvance.next(queueIds: [], contextIds: ["tot", "sub:song:ok"],
                                   isPlayable: { $0 != "tot" }, resolves: { _ in true })
        #expect(hit?.id == "sub:song:ok")
    }

    /// Der Auftrags-Fall WOERTLICH an der ganzen Kaskade: vor Stunden
    /// Musik-Zufall gestartet, dann ein Podcast angetippt (der Tipp toetet
    /// den Musik-Kontext), die Folge endet — es spielt die NAECHSTE FOLGE,
    /// nie die alte Musik. Die Rot-Probe daneben zeigt, dass genau das
    /// Toeten den Fall traegt: mit ueberlebendem Kontext haette die Musik
    /// gewonnen.
    @Test("Zufall, dann Podcast, dann Ende: die naechste Folge spielt, nie die alte Musik")
    func ownerCaseVerbatim() {
        func aufloesen(kontext: [String]) -> (id: String, origin: PlaybackAdvance.Origin)? {
            PlaybackAdvance.resolveNext(
                after: "rss:folge1",
                queueIds: [], contextIds: kontext,
                isPlayable: { _ in true }, resolves: { _ in true },
                isPodcast: { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") },
                bingeNext: { _ in "rss:folge2" },
                seriesEnabled: false, seriesNext: { _ in nil })
        }
        // Der Tipp hat den Kontext getoetet: die naechste Folge spielt.
        let hit = aufloesen(kontext: [])
        #expect(hit?.id == "rss:folge2" && hit?.origin == .binge)
        // Rot-Probe: haette der Kontext ueberlebt, gewaenne die alte Musik
        // (der Ist-Zustand vor dem Neubau, als der Sammlungs-Rest in der
        // Queue lag und Stufe 1 gewann).
        let alt = aufloesen(kontext: ["sub:song:altemusik"])
        #expect(alt?.id == "sub:song:altemusik",
                "die Probe saehe den Unterschied nicht")
        // Und: eine BESTELLUNG schlaegt das Binge (der Abendplan gilt).
        let bestellt = PlaybackAdvance.resolveNext(
            after: "rss:folge1", queueIds: ["book:krimi"], contextIds: [],
            isPlayable: { _ in true }, resolves: { _ in true },
            isPodcast: { _ in true }, bingeNext: { _ in "rss:folge2" },
            seriesEnabled: false, seriesNext: { _ in nil })
        #expect(bestellt?.id == "book:krimi" && bestellt?.origin == .order)
        // Buecher: die Serie antwortet nur mit eingeschalteter Vorgabe,
        // und Podcasts fallen NIE in die Serien-Stufe durch.
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

    // MARK: - Cross-media auto-continue (Teil-1 core journey)

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
