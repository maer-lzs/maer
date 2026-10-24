// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The listening history of books and songs: when a song counts, one entry
/// per title that moves to the top, a taken back "finished", the rows
/// across a restart, and the two ways in.
struct ListenHistoryRuleTests {
    @Test("ein Lied zaehlt ab der Haelfte oder ab vier Minuten, knapp darunter nicht; ohne Laenge nie")
    func theSongThreshold() {
        let under = ListenHistory.songHeard(song: "s", position: 89, duration: 180, noted: nil)
        let half = ListenHistory.songHeard(song: "s", position: 90, duration: 180, noted: nil)
        let long = ListenHistory.songHeard(song: "s", position: 240, duration: 1200, noted: nil)
        let longUnder = ListenHistory.songHeard(song: "s", position: 239, duration: 1200, noted: nil)
        let unknown = ListenHistory.songHeard(song: "s", position: 500, duration: 0, noted: nil)
        #expect(!under.enter, "a song counted just under half")
        #expect(half.enter, "a song did not count at half")
        #expect(long.enter, "a long song did not count at four minutes")
        #expect(!longUnder.enter, "a long song counted just under four minutes")
        #expect(!unknown.enter, "a song without a length counted")
    }

    @Test("ein Hoeren schreibt einmal; zurueck unter die Schwelle und wieder darueber ist ein neues Hoeren, ein anderes Lied auch")
    func oneHearingEntersOnce() {
        var noted: String?
        var entered: [Double] = []
        for position in [60.0, 95, 100, 150, 30, 120] {
            let step = ListenHistory.songHeard(song: "a#1", position: position, duration: 180, noted: noted)
            noted = step.noted
            if step.enter { entered.append(position) }
        }
        #expect(entered == [95, 120], "one hearing wrote more or less than once: \(entered)")
        let other = ListenHistory.songHeard(song: "a#2", position: 95, duration: 180, noted: noted)
        #expect(other.enter, "the next song did not count after the one before")
    }

    /// Which page a playing title belongs to: books of the books tab and
    /// titles on the books shelf (Booksonic) as books; server music and the
    /// music of the open catalogs song by song; podcasts and radio nowhere.
    @Test("Buch, Buch auf dem Buch-Regal (Booksonic), Server-Musik und Katalog-Musik gehen je auf ihre Seite; Podcast und Radio nirgends")
    func eachTitleGoesToItsPage() {
        let archive = FreeCatalog.archivePrefix + "release"
        let cases: [(String, ProgressMark.StartedForm?, Bool, ListenHistory.Family?)] = [
            ("abs-book-1", nil, false, .book),
            ("local:file", nil, false, .book),
            (FreeCatalog.librivoxPrefix + "1", nil, false, .book),
            ("sub:album:a", nil, true, .book),
            ("sub:album:a", nil, false, .music),
            ("jf:song:s", nil, false, .music),
            (archive, .album, false, .music),
            (archive, nil, false, .book),
            (CatalogSongID.make(album: archive, index: 2), nil, false, .music),
            (FreeCatalog.jamendoPrefix + "1", nil, false, .music),
            ("rss:feed:ep", nil, false, nil),
            ("radio:rb:x", nil, false, nil),
        ]
        for (id, form, shelf, expected) in cases {
            let family = ListenHistory.family(of: id, markedForm: form, onBookShelf: shelf)
            #expect(family == expected, "\(id) form \(String(describing: form)) shelf \(shelf) goes to \(String(describing: family))")
        }
        #expect(ListenHistory.catalogSongId(itemId: archive, trackIndex: 2, trackCount: 5) == CatalogSongID.make(album: archive, index: 2))
        let song = CatalogSongID.make(album: archive, index: 4)
        #expect(ListenHistory.catalogSongId(itemId: song, trackIndex: 0, trackCount: 1) == song, "a song address took another")
        let single = FreeCatalog.jamendoPrefix + "7"
        #expect(ListenHistory.catalogSongId(itemId: single, trackIndex: 0, trackCount: 1) == single, "a one-track title took an index")
    }

    /// A book enters once, when its phase turns into played: not with every
    /// tick while it stands played, again after a finish taken back.
    @Test("ein Buch kommt einmal herein, wenn es nach gehoert wechselt; nicht bei jedem Takt danach, wieder nach einem zurueckgenommenen Fertig", .needsTheSources)
    func aBookEntersWhenItTurnsPlayed() throws {
        typealias P = ProgressMark.PlayState.Phase
        let cases: [(P, P, Bool)] = [
            (.inProgress, .played, true),
            (.unplayed, .played, true),
            (.played, .played, false),
            (.played, .inProgress, false),
            (.inProgress, .inProgress, false),
            (.unplayed, .inProgress, false),
        ]
        for (before, after, expected) in cases {
            let finished = ListenHistory.bookFinished(before: before, after: after)
            #expect(finished == expected, "\(before) to \(after) finished \(finished)")
        }
        let player = StockDriftTests.squeezed(SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8)))
        #expect(player.contains("guardListenHistory.bookFinished(before:phaseBefore,after:phaseAfter)"),
                "the player decides a finished book beside the rule")
    }

    /// The player asks the one rule with the books shelf, and a catalog song
    /// takes its row id from the one rule.
    @Test("der Player fragt die eine Regel mit dem Buch-Regal, ein Katalog-Lied nimmt seine Kennung aus der Regel", .needsTheSources)
    func thePlayerAsksTheRule() throws {
        let player = StockDriftTests.squeezed(SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8)))
        #expect(player.contains("ListenHistory.family(of:id,") && player.contains("onBookShelf:AppSession.shared.libraryViewModel.entry(id:id)!=nil"),
                "the player decides the page beside the rule or without the books shelf")
        #expect(player.contains("ListenHistory.catalogSongId(itemId:id,"), "a catalog song takes another row id")
        #expect(player.components(separatedBy: "MediaFamily.booksTabMember(").count == 1,
                "the player asks the books tab beside the rule")
    }

    @Test("die Seite zeigt je Familie die gehoerten Eintraege, neueste zuerst, ohne zurueckgenommene")
    func thePageList() {
        typealias E = ListenHistory.Entry
        let entries: [String: E] = [
            "b1": E(id: "b1", family: .book, title: "B1", subtitle: "", heardAt: 10),
            "b2": E(id: "b2", family: .book, title: "B2", subtitle: "", heardAt: 30),
            "b3": E(id: "b3", family: .book, title: "B3", subtitle: "", heardAt: 20, unheardAt: 25),
            "s1": E(id: "s1", family: .music, title: "S1", subtitle: "", heardAt: 40),
        ]
        #expect(ListenHistory.historyList(entries, family: .book).map(\.id) == ["b2", "b1"])
        #expect(ListenHistory.historyList(entries, family: .music).map(\.id) == ["s1"])
    }

    @Test("ein Datum vor 2000 steht nicht")
    func noDateBefore2000() {
        let old = ListenHistory.Entry(id: "x", family: .book, title: "X", subtitle: "", heardAt: 3600)
        let now = ListenHistory.Entry(id: "y", family: .book, title: "Y", subtitle: "", heardAt: 1_700_000_000_000)
        #expect(ListenHistory.shownDate(old) == nil, "a date before 2000 is shown")
        #expect(ListenHistory.shownDate(now) == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Both tabs open the one page, each with its family: music and books,
    /// with and without a server, by the one entry row at the end of the
    /// tab (the podcast tab too); the episode history and this page draw
    /// the one row.
    @Test("beide Reiter oeffnen die eine Seite mit ihrer Familie, Musik und Buecher mit und ohne Server ueber die eine Reihe am Ende; beide Verlaeufe zeigen dieselbe Zeile", .needsTheSources)
    func bothTabsOpenTheOnePage() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(!LibraryListRoute.bookTabEntries.contains(.history), "the books tab deck carries a history tile again")
        #expect(LibraryListRoute.history.title == String(localized: "Listening History"))
        #expect(MusicRoute.history.accessibilityId == "music-route-history")
        let library = try code("Sources/Views/LibraryView.swift")
        let squeezedLibrary = FetchAnswerTests.squeezed(library)
        #expect(squeezedLibrary.contains("case .history: ListenHistoryScreen(family: .book)"),
                "the books route opens another page")
        #expect(library.contains("ListeningHistoryRow(route: LibraryListRoute.history"), "the books tab has no history row")
        #expect(squeezedLibrary.contains("historySection } else {") && squeezedLibrary.contains("bookTabDeck historySection }"),
                "the books tab ends without its history row, with or without a server")
        let music = try code("Sources/Views/Music/MusicNavigation.swift")
        #expect(FetchAnswerTests.squeezed(music).contains("case .history: ListenHistoryScreen(family: .music)"),
                "the music route opens another page")
        let tab = try code("Sources/Views/Music/MusicView.swift")
        #expect(tab.contains("ListeningHistoryRow(route: MusicRoute.history"), "the music tab has no history row at its end")
        #expect(!FetchAnswerTests.squeezed(tab).contains("route: .history)"), "the music deck carries a history tile again")
        let podcastTab = try code("Sources/Views/PodcastsView.swift")
        #expect(podcastTab.contains("ListeningHistoryRow(route: PodcastRoute.history"), "the podcast tab has its own history row again")
        var rows: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            if SyncContractFenceTests.stripped(text).contains("\"Title unknown\"") { rows.append(name) }
        }
        #expect(rows == ["HistoryRow.swift"], "a history row is drawn twice: \(rows.sorted())")
        let podcasts = try code("Sources/Views/Podcasts/PodcastHistoryView.swift")
        #expect(podcasts.contains("HistoryRow(title: entry.episodeTitle"), "the episode history draws a row of its own")
        // Read and sorted once per opening, off the main thread; one
        // continuous list without steps or a spinner.
        let screen = FetchAnswerTests.squeezed(try code("Sources/Views/ListenHistoryScreen.swift"))
        #expect(screen.contains(".task { guard !loaded else { return } entries = await ListenHistory.shared.historyOffMain(family)"),
                "the page does not read off the main thread, or reads again whenever it appears")
        #expect(!screen.contains(".history(family)"), "the page reads on the main thread again")
        #expect(!screen.contains("ProgressView") && !screen.contains("prefix("), "the page loads in steps again")
        // The store reads and sorts on background tasks.
        let store = try code("Sources/Storage/ListenHistory.swift")
        let offMain = try #require(store.range(of: "func historyOffMain"), "the off-main read is gone")
        let body = store[offMain.upperBound...].prefix(1400)
        #expect(body.components(separatedBy: "Task.detached").count == 3, "the read or the sort runs on the main thread")
        #expect(body.contains("RowKeeper<Entry>.readNow(") && body.contains("Self.historyList(snapshot"),
                "the background tasks do not read and sort")
    }
}

@MainActor
@Suite(.serialized)
struct ListenHistoryStoreTests {
    private struct Rig {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var shelf: RestingShelf { database.restingShelf! }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func rig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Rig(directory: directory)
    }

    private func songs(_ history: ListenHistory) -> [String] { history.history(.music).map(\.id) }
    private func books(_ history: ListenHistory) -> [String] { history.history(.book).map(\.id) }

    @Test("zweimal dasselbe Lied gehoert ist eine Zeile, oben; der Verlauf beginnt leer und steht nach einem Neustart")
    func twiceHeardIsOneRowOnTop() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let history = ListenHistory(database: rig.database, identity: { nil })
        #expect(songs(history).isEmpty && books(history).isEmpty, "the history did not start empty")
        history.noteHeard(id: "sub:song:a", family: .music, title: "A", subtitle: "X", at: 1_700_000_000_000)
        history.noteHeard(id: "sub:song:b", family: .music, title: "B", subtitle: "X", at: 1_700_000_100_000)
        history.noteHeard(id: "sub:song:a", family: .music, title: "A", subtitle: "X", at: 1_700_000_200_000)
        #expect(songs(history) == ["sub:song:a", "sub:song:b"], "a second hearing is a second row or stays below")
        await history.awaitPendingWrites()
        let later = ListenHistory(database: rig.database, identity: { nil })
        #expect(songs(later) == ["sub:song:a", "sub:song:b"], "a restart read another history: \(songs(later))")
        let top = later.history(.music).first?.heardAt
        #expect(top == 1_700_000_200_000, "the row does not carry the latest hearing")
    }

    @Test("die Seite liest abseits des Hauptstrangs dieselbe Liste wie der Speicher; danach haengt ein Hoeren oben an, ohne zweites Lesen")
    func thePageReadsOffTheMainThread() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let first = ListenHistory(database: rig.database, identity: { nil })
        for (index, id) in ["sub:song:a", "sub:song:b", "sub:song:c"].enumerated() {
            first.noteHeard(id: id, family: .music, title: id, subtitle: "", at: 1_700_000_000_000 + Double(index) * 1000)
        }
        first.noteHeard(id: "book-1", family: .book, title: "B", subtitle: "", at: 1_700_000_500_000)
        await first.awaitPendingWrites()
        #expect(first.startRead == .main, "a hearing read its rows somewhere else")
        let later = ListenHistory(database: rig.database, identity: { nil })
        let page = await later.historyOffMain(.music).map(\.id)
        #expect(later.startRead == .background, "the page read the rows on the main thread")
        #expect(page == ["sub:song:c", "sub:song:b", "sub:song:a"], "the page read another list: \(page)")
        let bookPage = await later.historyOffMain(.book).map(\.id)
        #expect(bookPage == ["book-1"])
        later.noteHeard(id: "sub:song:d", family: .music, title: "D", subtitle: "", at: 1_700_001_000_000)
        #expect(songs(later) == ["sub:song:d", "sub:song:c", "sub:song:b", "sub:song:a"],
                "the store read again over its rows or lost them: \(songs(later))")
    }

    @Test("fertig zurueckgenommen nimmt das Buch von der Seite, ein neueres Hoeren bringt es zurueck, ein aelteres nicht")
    func aTakenBackFinish() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let history = ListenHistory(database: rig.database, identity: { nil })
        history.noteHeard(id: "book-1", family: .book, title: "Book", subtitle: "Author", at: 1_700_000_000_000)
        history.markUnheard(id: "book-1", at: 1_700_000_100_000)
        #expect(books(history).isEmpty, "a taken back finish stays on the page")
        history.noteHeard(id: "book-1", family: .book, title: "Book", subtitle: "Author", at: 1_700_000_050_000)
        #expect(books(history).isEmpty, "an older hearing undid the tombstone")
        history.noteHeard(id: "book-1", family: .book, title: "Book", subtitle: "Author", at: 1_700_000_200_000)
        #expect(books(history) == ["book-1"], "a newer hearing did not bring the book back")
    }

    @Test("ohne Konto gehoert, das erste Konto A sieht alles; B sieht nichts von A; zurueck zu A, dann B: B's Eintraege wieder da, keiner von A")
    func theHistoryFollowsTheAccount() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        var signedIn: String?
        let history = ListenHistory(database: rig.database, identity: { signedIn })
        history.noteHeard(id: "device", family: .book, title: "D", subtitle: "", at: 1_700_000_000_000)

        signedIn = "account-a"
        #expect(history.follow(owner: "account-a", previous: nil))
        await history.awaitPendingWrites()
        #expect(books(history) == ["device"], "the first account does not take what this device heard")

        signedIn = "account-b"
        #expect(history.follow(owner: "account-b", previous: "account-a"))
        await history.awaitPendingWrites()
        #expect(books(history).isEmpty, "B sees what A heard: \(books(history))")
        history.noteHeard(id: "sub:song:b", family: .music, title: "B", subtitle: "", at: 1_700_000_100_000)

        signedIn = "account-a"
        #expect(history.follow(owner: "account-a", previous: "account-b"))
        await history.awaitPendingWrites()
        #expect(books(history) == ["device"] && songs(history).isEmpty, "A's own entries did not come back as they were")

        signedIn = "account-b"
        #expect(history.follow(owner: "account-b", previous: "account-a"))
        await history.awaitPendingWrites()
        #expect(songs(history) == ["sub:song:b"] && books(history).isEmpty, "B's entries did not come back, or A's came along")
        let later = ListenHistory(database: rig.database, identity: { signedIn })
        #expect(later.follow(owner: "account-b", previous: "account-b"))
        #expect(songs(later) == ["sub:song:b"], "a restart under B shows another stock: \(songs(later))")
    }

    @Test("unter B nach der Ersetzung gehoert, steht der Eintrag nach einem Neustart bei B, keiner von A")
    func anEntryHeardAfterTheReplacementSurvivesARestart() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        var signedIn: String? = "account-a"
        let history = ListenHistory(database: rig.database, identity: { signedIn })
        #expect(history.follow(owner: "account-a", previous: nil))
        history.noteHeard(id: "of-a", family: .book, title: "A", subtitle: "", at: 1_700_000_000_000)
        await history.awaitPendingWrites()

        signedIn = "account-b"
        #expect(history.follow(owner: "account-b", previous: "account-a"))
        history.noteHeard(id: "sub:song:of-b", family: .music, title: "B", subtitle: "", at: 1_700_000_100_000)
        await history.awaitPendingWrites()

        // A restart: a new store on the same file, under B.
        let later = ListenHistory(database: rig.database, identity: { signedIn })
        #expect(later.follow(owner: "account-b", previous: "account-a"))
        await later.awaitPendingWrites()
        #expect(songs(later) == ["sub:song:of-b"], "what B heard after the replacement is gone: \(songs(later))")
        #expect(books(later).isEmpty, "A's entry came along: \(books(later))")
    }

    @Test("ein Eintrag waehrend einer gehaltenen Uebergabe wartet und steht danach bei B, keiner bei A")
    func anEntryDuringAHeldHandOverWaits() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let before = ListenHistory(database: rig.database, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        before.noteHeard(id: "of-a", family: .book, title: "A", subtitle: "", at: 1_700_000_000_000)
        await before.awaitPendingWrites()

        let file = rig.directory.appendingPathComponent("maer.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let history = ListenHistory(database: rig.database, identity: { "account-b" })
        let handed = history.follow(owner: "account-b", previous: "account-a")
        history.noteHeard(id: "of-b", family: .book, title: "B", subtitle: "", at: 1_700_000_100_000)
        let waited = books(history)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(!handed, "the precondition: the switch held over unread rows")
        #expect(waited.isEmpty, "the entry went into the held history: \(waited)")

        #expect(history.follow(owner: "account-b", previous: "account-a"))
        await history.awaitPendingWrites()
        #expect(books(history) == ["of-b"], "the waiting entry was lost or A's came along: \(books(history))")
        let restOfA = try rig.shelf.rest(ListenHistory.Resting.self, of: ListenHistory.shelfFamily, owner: "account-a")
        let rested = Set(restOfA?.entries.keys.map { $0 } ?? [])
        #expect(rested == ["of-a"], "B's entry rests under A, or A's was lost: \(rested)")
    }

    @Test("wartet ein Eintrag unter B und gelingt dann der Wechsel zu C, landet er nicht bei C")
    func anEntryWaitingForBNeverLandsAtC() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let before = ListenHistory(database: rig.database, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        before.noteHeard(id: "of-a", family: .book, title: "A", subtitle: "", at: 1_700_000_000_000)
        await before.awaitPendingWrites()

        var signedIn = "account-b"
        let file = rig.directory.appendingPathComponent("maer.sqlite").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let history = ListenHistory(database: rig.database, identity: { signedIn })
        let handed = history.follow(owner: "account-b", previous: "account-a")
        history.noteHeard(id: "of-b", family: .book, title: "B", subtitle: "", at: 1_700_000_100_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(!handed, "the precondition: the switch to B held over unread rows")

        signedIn = "account-c"
        #expect(history.follow(owner: "account-c", previous: "account-a"))
        await history.awaitPendingWrites()
        #expect(!books(history).contains("of-b"), "what B heard landed at C: \(books(history))")
    }

    /// The two ways in stand once each: the tick of the player (a book into
    /// played, a song past its threshold) and the finish mark of a book.
    @Test("die Zuwege stehen je einmal: der Takt des Players fuer Buch und Lied, die Marke fertig mit Zuruecknehmen", .needsTheSources)
    func theWaysInStandOnce() throws {
        let player = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        let mark = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/BookFinishMark.swift"), encoding: .utf8))
        let tick = try #require(ABSPodcastRefreshTests.body(of: "private func noteListeningHistory(", in: player),
                                "the player has no way into the history")
        #expect(tick.contains("family: .book") && tick.contains("family: .music"), "the tick misses books or songs")
        #expect(tick.contains("ListenHistory.songHeard("), "the songs do not ask the one rule")
        #expect(player.components(separatedBy: "self.noteListeningHistory(").count == 2, "the tick calls the history not once")
        #expect(mark.contains("ListenHistory.shared.noteFinished(target,"),
                "the finish mark does not reach the history both ways")
        var callers: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "ListenHistory.swift" {
            let code = SyncContractFenceTests.stripped(text)
            if code.contains(".noteHeard(") || code.contains(".noteFinished(") || code.contains(".markUnheard(") {
                callers.append(name)
            }
        }
        #expect(callers.sorted() == ["BookFinishMark.swift", "PlayerViewModel.swift"], "another way into the history: \(callers.sorted())")
    }
}
#endif
