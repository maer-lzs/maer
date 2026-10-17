// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The shownotes of the subscribed episodes live in `episode_note`, not in
/// memory: the stock carries a stamp, the database the text, read when an
/// episode is opened. A fresh text replaces the stored one, a payload that
/// still carries notes gives them to the table before it goes, and no
/// note leaves with its episode row.
@MainActor
struct PodcastNotesTests {
    private func episode(_ guid: String, notes: String?) -> PodcastEpisode {
        var episode = PodcastEpisode(guid: guid, title: guid, audioURL: "https://notes.example/\(guid).mp3",
                                     pubDate: 1_700_000_000_000, duration: 600)
        episode.description = notes
        return episode
    }

    private func show(_ id: String, _ episodes: [PodcastEpisode]) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil, description: nil,
                    feedURL: "https://notes.example/\(id).xml", episodes: episodes)
    }

    private func memoryStore() async throws -> (PodcastRowStore, SQLiteConnection) {
        let db = try SQLiteConnection(path: ":memory:")
        return (try await PodcastRowStore(connection: db), db)
    }

    @Test("teilen nimmt die Shownotes aus dem Bestand, laesst einen Stempel, ein gleicher Text wird nicht neu geschrieben")
    func splitTakesTheNotesAndLeavesAStamp() throws {
        let stock = [show("a", [episode("e1", notes: "Text A"), episode("e2", notes: ""), episode("e3", notes: nil)])]
        let split = try #require(PodcastNotes.split(stock, stampBefore: { _ in nil }))
        #expect(split.notes == ["e1": "Text A"], "an empty text is no note")
        #expect(split.shows[0].episodes.allSatisfy { $0.description == nil })
        #expect(split.shows[0].episodes[0].notesStamp == PodcastNotes.stamp("Text A"))
        #expect(split.shows[0].episodes[2].notesStamp == nil)
        let again = try #require(PodcastNotes.split(stock, stampBefore: { $0 == "e1" ? PodcastNotes.stamp("Text A") : nil }))
        #expect(again.notes.isEmpty, "the same text under the same stamp is written again")
        #expect(PodcastNotes.split(split.shows, stampBefore: { _ in nil }) == nil, "a stock without notes passes untouched")
        #expect(PodcastNotes.stamp("Text A") == PodcastNotes.stamp("Text A"))
        #expect(PodcastNotes.stamp("Text A") != PodcastNotes.stamp("Text B"))
    }

    @Test("frischer Text ersetzt den gespeicherten")
    func aFreshTextReplacesTheStoredOne() async throws {
        let (store, _) = try await memoryStore()
        try await store.apply(PodcastRowDiff.compute(previous: [], current: [show("a", [episode("e1", notes: nil)])]),
                              notes: ["e1": "Text A"])
        #expect(try await store.notes(guid: "e1") == "Text A")
        try await store.apply(PodcastRowDiff.compute(previous: [], current: []), notes: ["e1": "Text B"])
        #expect(try await store.notes(guid: "e1") == "Text B", "the stored text stood over the fresh one")
    }

    @Test("eine Datenbank der Version 1 traegt die Shownotes nach dem Heben in der Tabelle, die Nutzlast ohne, Version 2")
    func theMoveCarriesTheNotesOut() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        // The tables and the version as a build of version 1 left them.
        for statement in Self.versionOneOpen { try await db.execute(statement) }
        try await db.setSchemaVersion(1, of: PodcastRowStore.family)
        let old = episode("e1", notes: "Alte Notiz")
        _ = try await db.run("INSERT INTO show (id, position, payload) VALUES ('a', 0, ?)",
                             [.blob(try JSONEncoder().encode(show("a", [])))])
        _ = try await db.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES ('e1', 'a', 0, 0, ?)",
                             [.blob(try JSONEncoder().encode(old))])

        let store = try await PodcastRowStore(connection: db)
        #expect(try await db.schemaVersion(of: PodcastRowStore.family) == 2)
        #expect(try await store.notes(guid: "e1") == "Alte Notiz")
        let payload = try #require(try await db.query("SELECT payload FROM episode WHERE guid = 'e1'").first?["payload"]?.data)
        let read = try JSONDecoder().decode(PodcastEpisode.self, from: payload)
        #expect(read.description == nil, "the payload still carries the notes")
        #expect(read.title == old.title, "the move changed the rest of the payload")
        let loaded = try await store.loadAll()
        #expect(loaded.first?.episodes.first?.guid == "e1", "the episode is gone after the move")
    }

    @Test("eine Nutzlast mit Shownotes gibt sie der Tabelle, bevor sie ueberschrieben oder entfernt wird, nie ueber eine stehende")
    func aPayloadWithNotesGivesThemBeforeItGoes() async throws {
        let (store, db) = try await memoryStore()
        try await store.apply(PodcastRowDiff.compute(previous: [], current: [show("a", [])]))
        // A row as an older build writes it, the notes in the payload.
        for (guid, text) in [("e1", "aus der Nutzlast"), ("e2", "geht mit dem Loeschen")] {
            _ = try await db.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, 'a', 0, 0, ?)",
                                 [.text(guid), .blob(try JSONEncoder().encode(episode(guid, notes: text)))])
        }
        // A slim write over it, and a removal.
        let slim = [show("a", [episode("e1", notes: nil)])]
        try await store.apply(PodcastRowDiff.compute(previous: [show("a", [episode("e1", notes: "x"), episode("e2", notes: "y")])],
                                                     current: slim))
        #expect(try await store.notes(guid: "e1") == "aus der Nutzlast", "a slim write took the notes")
        #expect(try await store.notes(guid: "e2") == "geht mit dem Loeschen", "the removal took the notes")
        // A newer note stands over what a payload carries.
        try await store.apply(PodcastRowDiff.compute(previous: [], current: []), notes: ["e1": "neuer"])
        _ = try await db.run("UPDATE episode SET payload = ? WHERE guid = 'e1'",
                             [.blob(try JSONEncoder().encode(episode("e1", notes: "aelter")))])
        _ = try await db.run("UPDATE episode SET payload = ? WHERE guid = 'e1'",
                             [.blob(try JSONEncoder().encode(episode("e1", notes: nil)))])
        #expect(try await store.notes(guid: "e1") == "neuer", "a payload's notes stood over the newer note")
    }

    @Test("eine Nutzlast, die kein JSON ist, traegt keine Shownotes: Heben, Ueberschreiben und Entfernen gehen durch, auch ueber Ausloesern in aelterer Form")
    func aPayloadThatIsNoJSONCarriesNoNotes() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        for statement in Self.versionOneOpen { try await db.execute(statement) }
        try await db.setSchemaVersion(1, of: PodcastRowStore.family)
        // A rescue in the form that read every payload as JSON.
        try await db.execute("CREATE TABLE episode_note (guid TEXT PRIMARY KEY, notes TEXT NOT NULL)")
        try await db.execute("""
            CREATE TRIGGER episode_note_rescue_delete BEFORE DELETE ON episode
            WHEN json_extract(CAST(OLD.payload AS TEXT), '$.description') IS NOT NULL
            BEGIN SELECT 1; END
            """)
        _ = try await db.run("INSERT INTO show (id, position, payload) VALUES ('a', 0, ?)",
                             [.blob(try JSONEncoder().encode(show("a", [])))])
        // A row in the form of a later build.
        let later = Data("an episode in a form of a later build".utf8)
        for guid in ["e1", "e2"] {
            _ = try await db.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, 'a', 0, 0, ?)",
                                 [.text(guid), .blob(later)])
        }

        let store = try await PodcastRowStore(connection: db)
        #expect(try await db.schemaVersion(of: PodcastRowStore.family) == 2)
        #expect(try await store.notes(guid: "e1") == nil)
        _ = try await db.run("UPDATE episode SET payload = ? WHERE guid = 'e1'", [.blob(later)])
        _ = try await db.run("DELETE FROM episode WHERE guid = 'e2'")
        #expect(try await store.counts() == PodcastRowStore.Counts(shows: 1, episodes: 1))
    }

    @Test("eine entfernte Sendung nimmt ihre Folgen mit, ihre Shownotes bleiben")
    func theNotesStayWhenTheRowsGo() async throws {
        let (store, _) = try await memoryStore()
        let stock = [show("a", [episode("e1", notes: nil)])]
        try await store.apply(PodcastRowDiff.compute(previous: [], current: stock), notes: ["e1": "bleibt"])
        try await store.apply(PodcastRowDiff.compute(previous: stock, current: []))
        #expect(try await store.counts() == PodcastRowStore.Counts(shows: 0, episodes: 0))
        #expect(try await store.notes(guid: "e1") == "bleibt", "the notes left with their episode row")
    }

    @Test("das Raeumen laesst Shownotes gehen, die keine Zeile und kein ruhender Bestand nennt")
    func theSweepKeepsWhatARowOrARestNames() async throws {
        let (store, db) = try await memoryStore()
        let stock = [show("a", [episode("e1", notes: nil)])]
        try await store.apply(PodcastRowDiff.compute(previous: [], current: stock),
                              notes: ["e1": "steht", "e2": "ruht", "e3": "niemand"])
        try await db.transaction([try PodcastRowStore.noteSweep(keeping: ["e2"])])
        #expect(try await store.notes(guid: "e1") == "steht", "the sweep took the notes of a row that stands")
        #expect(try await store.notes(guid: "e2") == "ruht", "the sweep took the notes a rest expects back")
        #expect(try await store.notes(guid: "e3") == nil, "notes nobody names stayed")
    }

    /// What a build of version 1 runs when it opens the rows: these three
    /// tables and their indexes, and the version only lifted, never lowered.
    nonisolated static let versionOneOpen = [
        "CREATE TABLE IF NOT EXISTS show (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload BLOB NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS episode (guid TEXT PRIMARY KEY, show_id TEXT NOT NULL REFERENCES show(id) ON DELETE CASCADE,
            position INTEGER NOT NULL, pub_date REAL NOT NULL, payload BLOB NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS episode_show ON episode(show_id, position)",
        "CREATE INDEX IF NOT EXISTS episode_published ON episode(pub_date)",
    ]

    /// Measured for the report: what a build of version 1 does with rows
    /// of version 2. It opens them as above, reads every row, and its
    /// write of a payload with notes over a slim one keeps the table's note.
    @Test("ein Bau der Version 1 liest eine Datenbank der Version 2, leert nichts, und sein Schrieb nimmt keine Notiz")
    func aVersionOneBuildReadsAndEmptiesNothing() async throws {
        let (store, db) = try await memoryStore()
        let stock = [show("a", [episode("e1", notes: nil), episode("e2", notes: nil)])]
        try await store.apply(PodcastRowDiff.compute(previous: [], current: stock), notes: ["e1": "Notiz"])

        for statement in Self.versionOneOpen { try await db.execute(statement) }
        if try await db.schemaVersion(of: PodcastRowStore.family) < 1 {
            try await db.setSchemaVersion(1, of: PodcastRowStore.family)
        }
        #expect(try await db.schemaVersion(of: PodcastRowStore.family) == 2, "the older build lowered the version")
        let rows = try await db.query("SELECT payload FROM episode ORDER BY guid")
        let read = rows.compactMap { $0["payload"]?.data }.compactMap { try? JSONDecoder().decode(PodcastEpisode.self, from: $0) }
        #expect(read.map(\.guid) == ["e1", "e2"], "the older build does not read every row")
        // Its write: the payload with the notes of its own parse, as it upserts.
        _ = try await db.run("""
            INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES ('e1', 'a', 0, 0, ?)
            ON CONFLICT(guid) DO UPDATE SET payload = excluded.payload
            """, [.blob(try JSONEncoder().encode(episode("e1", notes: "aus dem alten Bau")))])
        #expect(try await store.notes(guid: "e1") == "Notiz", "the older build's write took the table's note")
        #expect(try await store.counts() == PodcastRowStore.Counts(shows: 1, episodes: 2))
    }

    private func subscriptions(in folder: URL, defaults: UserDefaults) -> PodcastSubscriptions {
        PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                             database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                             defaults: defaults, isTheApp: false)
    }

    private func storedNotes(_ folder: URL, guid: String) throws -> String? {
        try SQLiteReader(path: folder.appendingPathComponent("maer.sqlite").path)
            .query("SELECT notes FROM episode_note WHERE guid = ?", [.text(guid)]).first?["notes"]?.string
    }

    /// Through the store: after a subscribe and after a refresh no episode
    /// in the stock carries notes, the database holds the fresh text, and a
    /// refresh that changes only one episode's text writes it without a
    /// further write. An episode the feed no longer carries stays (46-1).
    @Test("Abo und Abgleich: keine Shownotes im Bestand, in der Datenbank der frische Text, auch wenn sich nur der Text aendert")
    func theStockCarriesNoNotesAndAChangedTextLands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "notes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        defer {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist trotz Setzen zu, der Fall misst nichts")
        let feed = try #require(URL(string: "https://notes.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        let showId = PodcastSubscriptions.feedKey(feed.absoluteString)
        func fresh(_ texts: [String: String]) -> PodcastShow {
            PodcastShow(id: showId, title: "Notizen", author: nil, artworkURL: nil, description: nil,
                        feedURL: feed.absoluteString,
                        episodes: texts.keys.sorted().map { episode($0, notes: texts[$0]) })
        }
        let first = fresh(["rss:n:1": "Eins", "rss:n:2": "Zwei"])
        let corrected = fresh(["rss:n:1": "Eins, berichtigt"])
        let subs = subscriptions(in: folder, defaults: defaults)
        await subs.ensureLoaded()
        subs._testFeedFetcher = { _ in .show(first) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        await subs.awaitPendingWrites()
        #expect(subs.shows.allSatisfy { $0.episodes.allSatisfy { $0.description == nil } }, "the stock holds notes")
        #expect(try storedNotes(folder, guid: "rss:n:1") == "Eins")
        #expect(await subs.notes(guid: "rss:n:2") == "Zwei")

        // Only the text of one episode changes, and one episode leaves the feed.
        subs._testFeedFetcher = { _ in .show(corrected) }
        await subs.refreshAll()
        await subs.awaitPendingWrites()
        #expect(subs.shows.allSatisfy { $0.episodes.allSatisfy { $0.description == nil } }, "the refresh left notes in the stock")
        #expect(try storedNotes(folder, guid: "rss:n:1") == "Eins, berichtigt", "the changed text did not land")
        #expect(try storedNotes(folder, guid: "rss:n:2") == "Zwei")
        #expect(subs.shows.first?.episodes.count == 2, "an episode the feed no longer carries left the show")
    }

    /// The account that leaves at a hand-over keeps its shownotes for its
    /// return; an unsubscribe lets the show's shownotes go.
    @Test("Shownotes bleiben ueber eine Uebergabe und den Rueckweg, ein Abbestellen laesst sie gehen")
    func theNotesRestWithTheAccountAndGoWithTheShow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "notes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        defer {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist trotz Setzen zu, der Fall misst nichts")
        let feed = try #require(URL(string: "https://notes.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        let shown = PodcastShow(id: PodcastSubscriptions.feedKey(feed.absoluteString), title: "Notizen", author: nil,
                                artworkURL: nil, description: nil, feedURL: feed.absoluteString,
                                episodes: [episode("rss:r:1", notes: "Eins")])
        let subs = subscriptions(in: folder, defaults: defaults)
        await subs.ensureLoaded()
        #expect(subs.follow(owner: "account-a"))
        subs._testFeedFetcher = { _ in .show(shown) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        await subs.awaitPendingWrites()
        try #require(try storedNotes(folder, guid: "rss:r:1") == "Eins", "the precondition: the notes stand")

        func handOver(to owner: String) async throws -> Bool {
            var handed = subs.follow(owner: owner)
            for _ in 0..<100 where !handed {
                try await Task.sleep(for: .milliseconds(20))
                handed = subs.follow(owner: owner)
            }
            await subs.awaitPendingWrites()
            return handed
        }
        #expect(try await handOver(to: "account-b"))
        #expect(subs.shows.isEmpty, "the precondition: B holds no show")
        #expect(try storedNotes(folder, guid: "rss:r:1") == "Eins", "the hand-over took A's notes")
        // A write under B that removes rows: A's rest still names its episode.
        let otherFeed = try #require(URL(string: "https://notes.example/\(UUID().uuidString.prefix(8))/other.xml"))
        let other = PodcastShow(id: PodcastSubscriptions.feedKey(otherFeed.absoluteString), title: "Andere", author: nil,
                                artworkURL: nil, description: nil, feedURL: otherFeed.absoluteString,
                                episodes: [episode("rss:r:2", notes: "Zwei")])
        subs._testFeedFetcher = { _ in .show(other) }
        try #require(await subs.subscribe(urlString: otherFeed.absoluteString, notesCloud: false))
        await subs.awaitPendingWrites()
        subs.unsubscribe(id: other.id, notesCloud: false)
        await subs.awaitPendingWrites()
        #expect(try storedNotes(folder, guid: "rss:r:2") == nil, "B's unsubscribed show's notes stayed")
        #expect(try storedNotes(folder, guid: "rss:r:1") == "Eins", "a write under B took the notes A's rest expects back")
        #expect(try await handOver(to: "account-a"))
        #expect(subs.shows.map(\.id) == [shown.id], "the way back lost A's show")
        #expect(try storedNotes(folder, guid: "rss:r:1") == "Eins", "the way back lost the notes")

        subs.unsubscribe(id: shown.id, notesCloud: false)
        await subs.awaitPendingWrites()
        #expect(try storedNotes(folder, guid: "rss:r:1") == nil, "the unsubscribed show's notes stayed")
    }

    /// The number the order names: the text of 1,000 episodes held in
    /// memory before and after, with about 3 KB of shownotes each. Printed
    /// as `EPISODERAM`; the case holds only that the stock went slim.
    @Test("Messung: Textbytes von 1.000 Folgen im Speicher vor und nach dem Teilen")
    func theTextOfAThousandEpisodes() throws {
        let notes = String(repeating: "Shownotes mit Links und Kapiteln. ", count: 90)
        let stock = [show("m", (0..<1_000).map { n in
            var episode = episode("rss:m:\(n)", notes: notes + "\(n)")
            episode.imageURL = "https://notes.example/cover/\(n).jpg"
            return episode
        })]
        func textBytes(_ shows: [PodcastShow]) -> Int {
            shows.flatMap(\.episodes).reduce(0) { sum, e in
                sum + e.guid.utf8.count + e.title.utf8.count + e.audioURL.utf8.count
                    + (e.description?.utf8.count ?? 0) + (e.imageURL?.utf8.count ?? 0)
            }
        }
        let split = try #require(PodcastNotes.split(stock, stampBefore: { _ in nil }))
        let before = textBytes(stock), after = textBytes(split.shows)
        print("EPISODERAM episodes=1000 text_bytes_before=\(before) text_bytes_after=\(after) notes_bytes=\(before - after)")
        #expect(split.notes.count == 1_000, "the precondition: every episode carried notes")
        #expect(split.shows[0].episodes.allSatisfy { $0.description == nil })
    }
}
#endif
