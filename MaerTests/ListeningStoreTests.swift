// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The listening invariant: what you listen to always stands on the device
/// too. Every class, every source. The store owns the keys and the reading
/// of the `[Double]` shape, so no call site indexes it itself again.
struct ListeningStoreTests {

    /// Own suite per run: a test that writes into the real store poisons
    /// itself on the second run (the double-run criterion exists for this).
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "listening-store-\(UUID().uuidString)")!
    }

    @Test("the state comes back with names, not as an index")
    func marksHaveNames() {
        let d = suite()
        ListeningStore.record("li_x", position: 120, duration: 3600, atMs: 1_700_000_000_000, in: d)
        let mark = ListeningStore.mark("li_x", in: d)
        #expect(mark?.position == 120)
        #expect(mark?.updatedAtMs == 1_700_000_000_000)
        #expect(mark?.duration == 3600)
        #expect(mark?.source == .backup)
    }

    @Test("the flushed witness answers when the backup is gone")
    func flushedWitnessAnswers() {
        let d = suite()
        ListeningStore.record("li_x", position: 41, duration: 3600, atMs: 1_700_000_000_000, in: d)
        ListeningStore.noteFlushed("li_x", position: 41, atMs: 1_700_000_005_000, in: d)
        // Sync retires the backup. The witness stays. A deleted witness is
        // not a fact; that is the whole null-start lesson.
        ListeningStore.clearBackup("li_x", in: d)
        let mark = ListeningStore.mark("li_x", in: d)
        #expect(mark?.position == 41)
        #expect(mark?.source == .flushed)
    }

    @Test("the backup leads when both are there")
    func backupLeads() {
        let d = suite()
        ListeningStore.noteFlushed("li_x", position: 10, atMs: 1_700_000_000_000, in: d)
        ListeningStore.record("li_x", position: 99, duration: 3600, atMs: 1_700_000_009_000, in: d)
        #expect(ListeningStore.mark("li_x", in: d)?.source == .backup)
        #expect(ListeningStore.position("li_x", in: d) == 99)
    }

    @Test("a known duration survives a writer that does not know it")
    func durationSurvivesAnIgnorantWriter() {
        let d = suite()
        ListeningStore.record("rss:e1", position: 100, duration: 1800, atMs: 1_700_000_000_000, in: d)
        // The next tick knows no duration. It must not delete the reference
        // point (that is the ProgressMark.advancing contract, asserted here
        // because the store is now the only way in).
        ListeningStore.record("rss:e1", position: 140, duration: 0, atMs: 1_700_000_005_000, in: d)
        #expect(ListeningStore.mark("rss:e1", in: d)?.duration == 1800)
    }

    // MARK: - Classes: what a local state IS

    @Test("a live stream gets no position")
    func liveStreamsKeepNoPosition() {
        // The ticker is class-blind by construction, so a playing station used
        // to write a GROWING position for an endless stream. One entry per
        // station, forever. Nothing read it today, by luck of a positive list;
        // this train builds exactly the surface that would have.
        #expect(ListeningClasses.keepsPosition("radio:dlf") == false)
        #expect(ListeningClasses.keepsPosition("li_book") == true)
        #expect(ListeningClasses.keepsPosition("rss:episode") == true)
        #expect(ListeningClasses.keepsPosition("lva:release#2") == true)
        #expect(ListeningClasses.keepsPosition("local:file") == true)

        let d = suite()
        ListeningStore.record("radio:dlf", position: 300, duration: 0,
                              atMs: 1_700_000_000_000, in: d)
        #expect(ListeningStore.mark("radio:dlf", in: d) == nil)
        #expect(ListeningStore.positions(in: d).isEmpty)
    }

    @Test("the invariant holds for EVERY class")
    func everyClassKeepsALocalStand() {
        // One representative per class the app can play. The asymmetry that
        // produced the whole weekend's error family was exactly this list
        // having a hole in it.
        let classes: [(name: String, id: String)] = [
            ("ABS-Buch",        "li_abcdef"),
            ("ABS-Podcast",     "abspod:show#1"),
            ("RSS-Podcast",     "rss:https://feed#42"),
            ("Musik-Titel",     "sub:song:17"),
            ("Musik (Jellyfin)","jf:song:17"),
            ("Katalog-Werk",    "lv:176"),
            ("Katalog-Spur",    "lva:release#3"),
            ("Sideload",        "local:file-1"),
        ]
        for (name, id) in classes {
            let d = suite()
            ListeningStore.record(id, position: 123, duration: 456,
                                  atMs: 1_700_000_000_000, in: d)
            let mark = ListeningStore.mark(id, in: d)
            #expect(mark?.position == 123, "\(name) haelt keinen lokalen Stand")
            #expect(mark?.updatedAtMs == 1_700_000_000_000, "\(name) haelt keinen Zeitstempel")
        }
    }

    // MARK: - The catalog read path, without any source

    /// Condition for matrix row 3: the device row runs with a
    /// sideload (`local:`), because archive.org is a fixed foreign host and
    /// a test seam in production code would change exactly the path that the
    /// measurement is meant to prove. The CATALOG read path is covered here instead.
    /// Without network, without provider, without a stand-in.
    ///
    /// The statement: a catalog state is obtained solely from the local stock.
    /// No source is asked, because for this class there is
    /// none at all.
    @Test("a catalog state is obtained without any source")
    func catalogStandIsWonLocally() {
        let d = suite()
        let work = "lv:176"                                   // LibriVox work
        let track = CatalogSongID.make(album: "lva:some-release", index: 4)

        for id in [work, track] {
            ListeningStore.record(id, position: 412, duration: 3600,
                                  atMs: 1_700_000_000_000, in: d)
            let mark = ListeningStore.mark(id, in: d)
            #expect(mark?.position == 412, "\(id) haelt seinen Stand nicht lokal")
            #expect(mark?.source == .backup)
        }

        // And the Continue Listening building finds both without a source, each on
        // its TAB side: the work in the book building, the TRACK
        // (song id = music by design) in the music building. Neither
        // disappears.
        let defaults: [String: Any] = [
            AppStorageKeys.localPosition(work): [412.0, 1_700_000_000_000.0, 3600.0],
            AppStorageKeys.localPosition(track): [412.0, 1_700_000_000_000.0, 3600.0],
        ]
        let started = ContinueSources.started(in: defaults, serverKnows: [])
        #expect(started.map(\.id) == [work],
                "die Buch-Weiterhoeren-Bildung findet das Werk nicht ohne Quelle")
        #expect(started.allSatisfy { $0.position == 412 })
        let music = ContinueSources.positionless(in: defaults, serverKnows: [])
        #expect(music.map(\.id) == [track],
                "der Track muss die Musik-Seite erreichen statt zu verschwinden")
        #expect(ContinueSources.isLocallyTracked(work))
        #expect(ContinueSources.isLocallyTracked(track))
    }

    // MARK: - Move and forgetting

    @Test("a move does not paint over a newer state")
    func moveKeepsTheNewer() {
        let d = suite()
        // The device already listened to the server-side twin. That stand is
        // newer than the rss one being re-keyed onto it.
        ListeningStore.record("rss:e1", position: 30, duration: 1800, atMs: 1_000, in: d)
        ListeningStore.record("abspod:e1", position: 900, duration: 1800, atMs: 9_000, in: d)
        ListeningStore.move(from: "rss:e1", to: "abspod:e1", in: d)
        #expect(ListeningStore.position("abspod:e1", in: d) == 900,
                "der neuere Zielstand ueberlebt die Umschluesselung")
        #expect(ListeningStore.backup("rss:e1", in: d) == nil, "die alte Kennung ist leer")
    }

    /// A move onto itself wrote the state and then deleted it
    /// under the same id. No caller reaches that today, the next one
    /// can; the source closes it.
    @Test("a move onto itself changes nothing and reports nothing")
    func moveOntoItselfIsNothing() {
        let d = suite()
        ListeningStore.record("rss:e1", position: 30, duration: 1800, atMs: 1_000, in: d)
        ListeningStore.noteFlushed("rss:e1", position: 30, atMs: 1_000, in: d)
        let stand = ListeningStore.backup("rss:e1", in: d)
        let flushed = ListeningStore.flushed("rss:e1", in: d)
        #expect(stand != nil && flushed != nil, "Stand und Fluss-Eintrag stehen, sonst misst der Fall nichts")
        let announced = Mutex(0)
        ListeningStore.listen(to: d, ListeningStore.Listener(
            wrote: { _, _ in announced.withLock { $0 += 1 } },
            wroteFlushed: { _, _ in announced.withLock { $0 += 1 } },
            replaces: { _ in false }))
        defer { ListeningStore.listen(to: d, nil) }

        ListeningStore.move(from: "rss:e1", to: "rss:e1", in: d)

        #expect(ListeningStore.backup("rss:e1", in: d) == stand, "der Stand steht")
        #expect(ListeningStore.flushed("rss:e1", in: d) == flushed, "der Fluss-Eintrag steht")
        #expect(announced.withLock { $0 } == 0, "keine Meldung")
    }

    /// One listener per stock. A suite that sets its listener after this
    /// one, on a stock of its own, as a parallel run does, takes nothing
    /// from this stock; removing it leaves this one. With one place for all
    /// stocks, the later listener took every write and every replacement.
    @Test("one listener per stock: a later one on another stock takes from this one neither writing nor flow nor replacing")
    func oneListenerPerStock() {
        let mine = suite(), other = suite()
        let heard = Mutex<[String]>([])
        func listener(_ name: String) -> ListeningStore.Listener {
            ListeningStore.Listener(
                wrote: { id, _ in heard.withLock { $0.append("\(name) wrote \(id)") } },
                wroteFlushed: { id, _ in heard.withLock { $0.append("\(name) flushed \(id)") } },
                replaces: { replacement in heard.withLock { $0.append("\(name) replaces \(replacement.name)") }; return true })
        }
        defer {
            ListeningStore.listen(to: mine, nil)
            ListeningStore.listen(to: other, nil)
        }
        ListeningStore.listen(to: mine, listener("mine"))
        ListeningStore.listen(to: other, listener("other"))

        ListeningStore.record("rss:m", position: 30, duration: 600, atMs: 1_000, in: mine)
        ListeningStore.noteFlushed("rss:m", position: 30, atMs: 1_000, in: mine)
        ListeningStore.replaceForNewOwner(with: nil, where: { _ in true }, in: mine, replacement: ListeningStore.Replacement(
            family: "podcasts", name: "to-b", travels: { _ in true }, landed: {}))
        ListeningStore.listen(to: other, nil)
        ListeningStore.record("rss:n", position: 40, duration: 600, atMs: 2_000, in: mine)

        #expect(heard.withLock { $0 } == ["mine wrote rss:m", "mine flushed rss:m", "mine replaces to-b", "mine wrote rss:n"])
    }

    @Test("a move onto an empty target carries the state over")
    func moveOntoEmptyCarries() {
        let d = suite()
        ListeningStore.record("rss:e1", position: 30, duration: 1800, atMs: 1_000, in: d)
        ListeningStore.move(from: "rss:e1", to: "abspod:e1", in: d)
        #expect(ListeningStore.position("abspod:e1", in: d) == 30)
        #expect(ListeningStore.backup("rss:e1", in: d) == nil)
    }

    @Test("the newer rule is pure and knows missing sides")
    func newerIsPure() {
        #expect(ListeningStore.newer([5, 100], nil) == [5, 100])
        #expect(ListeningStore.newer([5, 100], [7, 200]) == [7, 200])
        #expect(ListeningStore.newer([5, 300], [7, 200]) == [5, 300])
        // Tie: the incoming side wins, so that the move moves
        // anything at all.
        #expect(ListeningStore.newer([5, 200], [7, 200]) == [5, 200])
    }

    @Test("only the user intent removes, and then both keys")
    func onlyUserIntentRemoves() {
        let d = suite()
        ListeningStore.record("local:f", position: 10, duration: 100, atMs: 1_000, in: d)
        ListeningStore.noteFlushed("local:f", position: 10, atMs: 1_000, in: d)
        ListeningStore.forgetUserDeleted("local:f", in: d)
        #expect(ListeningStore.mark("local:f", in: d) == nil)
        #expect(ListeningStore.flushed("local:f", in: d) == nil)
    }

    @Test("the stock can be walked and filters the classes")
    func scanningFiltersClasses() {
        let d = suite()
        ListeningStore.record("li_a", position: 10, duration: 100, atMs: 1_000, in: d)
        ListeningStore.record("rss:b", position: 20, duration: 200, atMs: 2_000, in: d)
        ListeningStore.record("radio:c", position: 30, duration: 0, atMs: 3_000, in: d)
        let ids = Set(ListeningStore.positions(in: d).keys)
        #expect(ids == ["li_a", "rss:b"])
    }
}
#endif
