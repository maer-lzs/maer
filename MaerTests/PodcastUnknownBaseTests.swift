// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Rows the start could not read leave the base unknown. A show this run
/// read and the person then unsubscribed goes with the next write as a
/// removal and stays gone after a restart; a row nobody could read stays.
@MainActor
struct PodcastUnknownBaseTests {
    private static func show(_ url: String) -> PodcastShow {
        let key = PodcastSubscriptions.feedKey(url)
        return PodcastShow(id: "feed:\(key)", title: "Sendung \(key.prefix(6))", author: nil, artworkURL: nil,
                           description: nil, feedURL: url,
                           episodes: (0..<2).map {
                               PodcastEpisode(guid: "rss:\(key):\($0)", title: "Folge \($0)",
                                              audioURL: "https://feeds.example.org/\(key)/\($0).mp3",
                                              pubDate: Double($0 + 1) * 1000, duration: 600)
                           })
    }

    @Test("bei unbekannter Grundlage bleibt eine abbestellte Sendung nach dem Neustart weg, eine nie gelesene Zeile bleibt")
    func anUnsubscribeSurvivesTheRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "unknown-base-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let run = UUID().uuidString.prefix(8)
        let gone = Self.show("https://feeds.example.org/\(run)/weg.xml")
        let kept = Self.show("https://feeds.example.org/\(run)/bleibt.xml")
        let foreignId = "feed:fremd-\(run)"
        let database = MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path)
        let connection = try database.connection()
        try await PodcastRowStore(connection: connection).replaceAll([gone, kept])
        // A row a later shape wrote: nobody here can read it.
        _ = try await connection.run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                     [.text(foreignId), .integer(9), .blob(Data("spaeter".utf8))])

        func start() async -> PodcastSubscriptions {
            let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                            database: database, defaults: defaults, isTheApp: false)
            await subs.ensureLoaded()
            await subs.awaitPendingWrites()
            return subs
        }

        let first = await start()
        #expect(Set(first.shows.map(\.id)) == [gone.id, kept.id], "the precondition: both readable shows loaded")
        let before = try await PodcastRowStore(connection: connection).loadAllCounted()
        #expect(before.skipped == 1, "the precondition: one row nobody can read, so the base is unknown")
        first.unsubscribe(id: gone.id, notesCloud: false)
        await first.awaitPendingWrites()

        let second = await start()
        #expect(second.shows.map(\.id) == [kept.id], "after the restart: \(second.shows.map(\.id))")
        let after = try await PodcastRowStore(connection: connection).loadAllCounted()
        #expect(after.shows.map(\.id) == [kept.id], "rows: \(after.shows.map(\.id))")
        #expect(after.skipped == 1, "the row nobody could read was buried")
        let foreign = try await connection.query("SELECT id FROM show WHERE id = ?", [.text(foreignId)])
        #expect(foreign.count == 1, "the row nobody could read is gone")
    }
}
#endif
