// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The row store gives the stock back in its order, applies a diff as the
/// rows it names, takes removed shows' episodes with them, and never drops
/// the rest for one row it cannot read.
struct PodcastRowStoreTests {
    private func episode(_ n: Int, show: String) -> PodcastEpisode {
        var episode = PodcastEpisode(guid: "rss:\(show):\(n)", title: "Episode \(n)",
                                     audioURL: "https://example.org/\(show)/\(n).mp3",
                                     pubDate: Double(1_700_000_000_000 + n * 86_400_000), duration: 1800)
        episode.persons = [PodcastPerson(name: "Host", role: "host", img: nil, href: nil)]
        return episode
    }

    private func show(_ id: String, episodes: Int) -> PodcastShow {
        var show = PodcastShow(id: id, title: "Show \(id)", author: "Author", artworkURL: nil, description: "About",
                               feedURL: "https://example.org/\(id).xml",
                               episodes: (0..<episodes).reversed().map { episode($0, show: id) })
        show.funding = [PodcastFunding(url: "https://example.org/support", label: "Support")]
        show.origin = id == "b" ? "mirror" : nil
        return show
    }

    private func store() async throws -> (PodcastRowStore, SQLiteConnection) {
        let db = try SQLiteConnection(path: ":memory:")
        return (try await PodcastRowStore(connection: db), db)
    }

    @Test("Ersetzen und Zurücklesen: Reihenfolge der Sendungen und der Folgen, jedes Feld")
    func replaceAllRoundTrip() async throws {
        let (store, _) = try await store()
        let stock = [show("a", episodes: 3), show("b", episodes: 2), show("c", episodes: 0)]
        let counts = try await store.replaceAll(stock)
        #expect(counts == PodcastRowStore.Counts(shows: 3, episodes: 5))
        #expect(try await store.loadAll() == stock)
        // A second replace over a filled table is the new stock, nothing left over.
        try await store.replaceAll([stock[1]])
        #expect(try await store.loadAll() == [stock[1]])
        #expect(try await store.counts() == PodcastRowStore.Counts(shows: 1, episodes: 2))
    }

    @Test("Ein Diff schreibt die genannten Zeilen; eine entfernte Sendung nimmt ihre Folgen mit; leer ist ein No-op")
    func applyWritesTheNamedRows() async throws {
        let (store, _) = try await store()
        let before = [show("a", episodes: 3), show("b", episodes: 2)]
        try await store.replaceAll(before)
        var after = before
        after[0].episodes.insert(episode(9, show: "a"), at: 0)
        after[1].title = "Renamed"
        let diff = PodcastRowDiff.compute(previous: before, current: after)
        let counts = try await store.apply(diff)
        #expect(counts == PodcastRowStore.Counts(shows: 1, episodes: 4))
        #expect(try await store.loadAll() == after)
        // Remove a show: its rows go with it.
        try await store.apply(PodcastRowDiff.compute(previous: after, current: [after[1]]))
        #expect(try await store.counts() == PodcastRowStore.Counts(shows: 1, episodes: 2))
        #expect(try await store.loadAll() == [after[1]])
        // Nothing changed: nothing written.
        #expect(try await store.apply(PodcastRowDiff()) == PodcastRowStore.Counts(shows: 0, episodes: 0))
    }

    @Test("Eine unlesbare Zeile wird uebersprungen, der Rest kommt; die Familie hat ihre eigene Schema-Version")
    func unreadableRowIsSkipped() async throws {
        let (store, db) = try await store()
        try await store.replaceAll([show("a", episodes: 2)])
        try await db.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)",
                         [.text("rss:a:broken"), .text("a"), .integer(9), .real(0), .blob(Data("nonsense".utf8))])
        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].episodes.map(\.guid) == ["rss:a:1", "rss:a:0"])
        #expect(try await db.schemaVersion(of: PodcastRowStore.family) == PodcastRowStore.schemaVersion)
        #expect(try await db.schemaVersion(of: "somebody-else") == 0)
    }
}
#endif
