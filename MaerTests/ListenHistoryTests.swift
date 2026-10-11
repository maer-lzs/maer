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
