// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// What the cross check against the other platforms found in iOS: a
/// listening event before the books tab's first load is caught up, the
/// book page and the history page follow every event, an unreadable
/// history says so instead of "nothing yet", a stamp register of the wrong
/// form is not overwritten, an unreadable keychain entry is said once per
/// run, and an archive.org answer to another query is refused. The large
/// player's AirPlay mark keeps no colour of its own for a route in use.
@MainActor
struct SliceTwoCTests {
    static func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    // MARK: A listening event before the first load

    @Test("an event before the first load is kept and caught up once after it; after the load every event acts at once")
    func catchUp() {
        var rule = RevisionCatchUp()
        let early = rule.bump(loaded: false)
        let caughtUp = rule.loaded()
        let again = rule.loaded()
        let late = rule.bump(loaded: true)
        let afterLate = rule.loaded()
        #expect(!early, "nothing loaded yet: no rebuild from an empty cache")
        #expect(caughtUp, "the load catches the kept event up")
        #expect(!again, "caught up once")
        #expect(late)
        #expect(!afterLate, "an event after the load leaves nothing to catch up")
    }

    @Test("Fence: the books tab keeps an early event, the book page and the history page follow the revision", .needsTheSources)
    func surfacesFollow() throws {
        let library = try Self.source("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("catchUp.bump(loaded:"), "the books tab still drops an early event")
        #expect(library.contains("catchUp.loaded()"))
        let book = try Self.source("Sources/Views/BookDetailScreen.swift")
        #expect(book.contains("@ObservedObject private var revision = ListeningRevision.shared"))
        let history = try Self.source("Sources/Views/ListenHistoryScreen.swift")
        #expect(history.contains("@ObservedObject private var revision = ListeningRevision.shared"))
        #expect(history.contains(".task(id: revision.value)"), "the history page reads once per opening")
    }

    // MARK: Unreadable is not empty

    @Test("a history whose rows cannot be read says so; the page does not call it empty")
    func unreadableHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hist-unread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE listen_history (other TEXT)")
        try await connection.execute("INSERT INTO listen_history (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        let history = ListenHistory(database: database, identity: { nil })
        let entries = await history.historyOffMain(.book)
        #expect(entries.isEmpty)
        #expect(history.rowsUnread, "an unreadable history reads as empty")
        let page = try Self.source("Sources/Views/ListenHistoryScreen.swift")
        #expect(page.contains("if unread {"), "the page has no state for an unreadable history")
        #expect(page.contains("Text(\"Your listening history cannot be read on this device right now.\")"))
    }

    // MARK: A stamp register of the wrong form

    @Test("a stamp register of the wrong form is not overwritten by the next stamp; one of the right form stamps as before")
    func wrongFormStays() throws {
        let suite = "stamps-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://music.example", forKey: AppStorageKeys.subsonicServerURL)
        defaults.set(["sub:song:1": 7], forKey: MusicServerStampBook.storageKey)
        MusicServerStampBook.stamp("sub:song:2", kind: .history, in: defaults)
        #expect(defaults.dictionary(forKey: MusicServerStampBook.storageKey) as? [String: Int] == ["sub:song:1": 7],
                "the next stamp wrote over a register nobody could read")
        #expect(MusicServerStampBook.isUnreadable(in: defaults))
        let fresh = "stamps-\(UUID().uuidString)"
        let clean = try #require(UserDefaults(suiteName: fresh))
        defer { clean.removePersistentDomain(forName: fresh) }
        clean.set("https://music.example", forKey: AppStorageKeys.subsonicServerURL)
        MusicServerStampBook.stamp("sub:song:2", kind: .history, in: clean)
        #expect(clean.dictionary(forKey: MusicServerStampBook.storageKey) != nil)
        #expect(!MusicServerStampBook.isUnreadable(in: clean))
        let book = try Self.source("Sources/Models/MusicServerStamps.swift")
        #expect(book.contains("MUSICSTAMPS register unreadable"), "the wrong form passes without a line")
    }

    // MARK: The lock not readable

    @Test("an unreadable keychain entry is said once per run and key, not at every read")
    func onceAKey() throws {
        var once = FailureOnce()
        let first = once.first("premium.a")
        let second = once.first("premium.a")
        let other = once.first("premium.b")
        #expect(first)
        #expect(!second)
        #expect(other)
        let keychain = try Self.source("Sources/Networking/KeychainStore.swift")
        #expect(keychain.contains("failedReads.withLock { $0.first(key) }"), "every read of an unreadable entry still writes its line")
    }

    // MARK: An answer to another query

    @Test("an archive.org answer is checked against its query: the collection, and a shelf's subject as a word")
    func scrapeAnswer() {
        let shelf = "collection:georgeblood AND subject:\"Jazz\" AND mediatype:(audio)"
        let union = "collection:georgeblood AND subject:(\"Jazz\" OR \"Blues\") AND mediatype:(audio)"
        let own = [(collections: ["georgeblood", "78rpm"], subjects: ["Jazz", "Dance band"])]
        #expect(!ScrapeAnswerCheck.foreign(query: shelf, items: own))
        #expect(ScrapeAnswerCheck.foreign(query: shelf, items: own + [(collections: ["opensource_audio"], subjects: ["Jazz"])]),
                "another collection")
        #expect(ScrapeAnswerCheck.foreign(query: shelf, items: [(collections: ["georgeblood"], subjects: ["Polka"])]),
                "the shelf's subject is missing")
        #expect(ScrapeAnswerCheck.foreign(query: shelf, items: [(collections: ["georgeblood"], subjects: ["Jazzercise"])]),
                "the subject only as part of a word")
        #expect(!ScrapeAnswerCheck.foreign(query: union, items: [(collections: ["georgeblood"], subjects: ["blues"])]))
        #expect(!ScrapeAnswerCheck.foreign(query: "collection:netlabels AND mediatype:(audio)",
                                           items: [(collections: ["netlabels"], subjects: [])]))
        #expect(!ScrapeAnswerCheck.foreign(query: shelf, items: []), "an empty answer is a clean answer")
    }

    @Test("Fence: the scrape asks the collection and refuses a foreign answer", .needsTheSources)
    func scrapeWiring() throws {
        let fetch = try Self.source("Sources/Networking/CatalogStockFetch.swift")
        #expect(fetch.contains("\"identifier,title,creator,subject,downloads,licenseurl,year,collection\""))
        #expect(fetch.contains("ScrapeAnswerCheck.foreign(query: query,"))
        #expect(fetch.contains("CATALOGSTOCK answer refused"))
    }

    // MARK: The large player's AirPlay mark

    @Test("Fence: the large player's AirPlay mark keeps no colour of its own for a route in use", .needsTheSources)
    func largePlayerAirPlay() throws {
        let player = try Self.source("Sources/Views/PlayerView.swift")
        #expect(!player.contains("activeTintColor: AppTheme.accentUIColor"))
        #expect(player.components(separatedBy: "AirPlayButton(tintColor: .white)").count - 1 == 2)
    }
}
#endif
