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
    private static func show(_ url: String, mirrored: Bool = false) -> PodcastShow {
        let key = PodcastSubscriptions.feedKey(url)
        var show = PodcastShow(id: "feed:\(key)", title: "Sendung \(key.prefix(6))", author: nil, artworkURL: nil,
                           description: nil, feedURL: url,
                           episodes: (0..<2).map {
                               PodcastEpisode(guid: "rss:\(key):\($0)", title: "Folge \($0)",
                                              audioURL: "https://feeds.example.org/\(key)/\($0).mp3",
                                              pubDate: Double($0 + 1) * 1000, duration: 600)
                           })
        show.origin = mirrored ? "mirror" : nil
        return show
    }

    /// A folder, a defaults suite and a database of their own, removed after
    /// `body`.
    private func withOwnStore(_ body: (URL, UserDefaults, MaerDatabase) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "unknown-base-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(folder, defaults, MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
    }

    private func make(_ folder: URL, _ defaults: UserDefaults, _ database: MaerDatabase) -> PodcastSubscriptions {
        PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                             database: database, defaults: defaults, isTheApp: false)
    }

    /// A row a later shape wrote: nobody here can read it, so the base of a
    /// start over these rows is unknown.
    private func insertForeignRow(_ connection: SQLiteConnection, id: String) async throws {
        _ = try await connection.run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                     [.text(id), .integer(9), .blob(Data("spaeter".utf8))])
    }

    private func refusalNote(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("podcast_subscriptions.json")
            .appendingPathExtension("wipe-refused.txt").path)
    }

    @Test("bei unbekannter Grundlage entfernt ein leerer Schnappschuss ohne Absicht nichts, die Verweigerung hinterlaesst ihre Notiz")
    func anEmptySnapshotUnderAnUnknownBaseIsRefused() async throws {
        try await withOwnStore { folder, defaults, database in
            let run = UUID().uuidString.prefix(8)
            let mirrored = Self.show("https://feeds.example.org/\(run)/kanal.xml", mirrored: true)
            let connection = try database.connection()
            try await PodcastRowStore(connection: connection).replaceAll([mirrored])
            try await insertForeignRow(connection, id: "feed:fremd-\(run)")
            let subs = make(folder, defaults, database)
            await subs.ensureLoaded()
            #expect(subs.shows.map(\.id) == [mirrored.id], "the precondition: the mirrored show loaded")
            subs.removeMirrored(feedURL: mirrored.feedURL)
            await subs.awaitPendingWrites()
            let rows = try await PodcastRowStore(connection: connection).loadAllCounted()
            #expect(rows.shows.map(\.id) == [mirrored.id], "an empty snapshot without intent removed rows")
            #expect(refusalNote(folder), "the refusal left no note")
        }
    }

    @Test("scheitert die volle Lesung nach den Koepfen, bleibt eine Abbestellung nach dem Neustart weg")
    func anUnsubscribeAfterAFailedFullReadSurvives() async throws {
        try await withOwnStore { folder, defaults, database in
            let run = UUID().uuidString.prefix(8)
            let gone = Self.show("https://feeds.example.org/\(run)/weg.xml")
            let kept = Self.show("https://feeds.example.org/\(run)/bleibt.xml")
            let connection = try database.connection()
            try await PodcastRowStore(connection: connection).replaceAll([gone, kept])
            let first = make(folder, defaults, database)
            first._testFullReadFails = true
            await first.ensureLoaded()
            #expect(Set(first.shows.map(\.id)) == [gone.id, kept.id], "the precondition: the heads stand")
            #expect(first.shows.allSatisfy { $0.episodes.isEmpty }, "the precondition: only the heads were read")
            first.unsubscribe(id: gone.id, notesCloud: false)
            await first.awaitPendingWrites()
            let second = make(folder, defaults, database)
            await second.ensureLoaded()
            #expect(second.shows.map(\.id) == [kept.id], "after the restart: \(second.shows.map(\.id))")
            #expect(second.shows.first?.episodes.count == 2, "the kept show lost its episodes")
        }
    }

    @Test("zwei eingereihte Schriebe bei unbekannter Grundlage, der zweite leer: der leere entfernt nichts")
    func twoQueuedWritesUnderAnUnknownBase() async throws {
        try await withOwnStore { folder, defaults, database in
            let run = UUID().uuidString.prefix(8)
            let first = Self.show("https://feeds.example.org/\(run)/eins.xml", mirrored: true)
            let second = Self.show("https://feeds.example.org/\(run)/zwei.xml", mirrored: true)
            let connection = try database.connection()
            try await PodcastRowStore(connection: connection).replaceAll([first, second])
            try await insertForeignRow(connection, id: "feed:fremd-\(run)")
            let subs = make(folder, defaults, database)
            await subs.ensureLoaded()
            // Both handed over before the first lands.
            subs.removeMirrored(feedURL: first.feedURL)
            subs.removeMirrored(feedURL: second.feedURL)
            await subs.awaitPendingWrites()
            let rows = try await PodcastRowStore(connection: connection).loadAllCounted()
            #expect(rows.shows.map(\.id) == [second.id], "rows: \(rows.shows.map(\.id))")
            #expect(rows.skipped == 1, "the row nobody could read was buried")
            #expect(refusalNote(folder), "the refusal left no note")
        }
    }

    /// The guard is asked of the base the write really takes, not of the one
    /// at the moment the write was handed over: on fresh rows the first
    /// write has not landed yet when the empty one is queued.
    @Test("der Schutz fragt die Grundlage, die der Schrieb nimmt: frisch, ein Schrieb und ein leerer eingereiht, nichts entfernt")
    func theGuardAsksTheBaseTheWriteTakes() async throws {
        try await withOwnStore { folder, defaults, database in
            let show = Self.show("https://feeds.example.org/\(UUID().uuidString.prefix(8))/frisch.xml")
            let subs = make(folder, defaults, database)
            await subs.ensureLoaded()
            #expect(subs.shows.isEmpty, "the precondition: fresh rows")
            subs._testPersist([show])
            subs._testPersist([])
            await subs.awaitPendingWrites()
            let rows = try await PodcastRowStore(connection: try database.connection()).loadAllCounted()
            #expect(rows.shows.map(\.id) == [show.id], "the queued empty snapshot removed the show")
            #expect(refusalNote(folder), "the refusal left no note")
        }
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
