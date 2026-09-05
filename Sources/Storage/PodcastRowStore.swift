// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The subscription stock as rows: one row per show (its head, without
/// episodes) and one row per episode, the show as foreign key. A change is
/// an upsert of the rows it touched (`PodcastRowDiff`), never the whole
/// stock; the start reads the rows back in their order.
///
/// Each row carries its record as JSON: the shape of `PodcastShow` and
/// `PodcastEpisode` stays the one the app speaks, and a field added to the
/// record needs no column. The columns beside it are the facts a query
/// needs without decoding: ids, position, publication.
actor PodcastRowStore {
    static let family = "podcast"
    static let schemaVersion = 1

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) async throws {
        self.connection = connection
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS show (
                id TEXT PRIMARY KEY,
                position INTEGER NOT NULL,
                payload BLOB NOT NULL
            )
            """)
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS episode (
                guid TEXT PRIMARY KEY,
                show_id TEXT NOT NULL REFERENCES show(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                pub_date REAL NOT NULL,
                payload BLOB NOT NULL
            )
            """)
        try await connection.execute("CREATE INDEX IF NOT EXISTS episode_show ON episode(show_id, position)")
        try await connection.execute("CREATE INDEX IF NOT EXISTS episode_published ON episode(pub_date)")
        if try await connection.schemaVersion(of: Self.family) < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    struct Counts: Equatable, Sendable {
        var shows: Int
        var episodes: Int
    }

    func counts() async throws -> Counts {
        let shows = Int(try await connection.query("SELECT count(*) AS n FROM show").first?["n"]?.int64 ?? 0)
        let episodes = Int(try await connection.query("SELECT count(*) AS n FROM episode").first?["n"]?.int64 ?? 0)
        return Counts(shows: shows, episodes: episodes)
    }

    /// The show list without its episodes, in list order: what a start
    /// that fetches episodes on demand reads.
    func loadHeads() async throws -> [PodcastShow] {
        let decoder = JSONDecoder()
        var heads: [PodcastShow] = []
        for row in try await connection.query("SELECT payload FROM show ORDER BY position") {
            guard let data = row["payload"]?.data, let show = try? decoder.decode(PodcastShow.self, from: data) else { continue }
            heads.append(show)
        }
        return heads
    }

    /// The whole stock, shows in list order, episodes in their order. A row
    /// that does not decode is skipped and counted, never a reason to drop
    /// the rest.
    func loadAll() async throws -> [PodcastShow] {
        let decoder = JSONDecoder()
        var shows: [PodcastShow] = []
        var skipped = 0
        for row in try await connection.query("SELECT payload FROM show ORDER BY position") {
            guard let data = row["payload"]?.data, let show = try? decoder.decode(PodcastShow.self, from: data) else {
                skipped += 1
                continue
            }
            shows.append(show)
        }
        var index: [String: Int] = [:]
        for (i, show) in shows.enumerated() { index[show.id] = i }
        for row in try await connection.query("SELECT show_id, payload FROM episode ORDER BY show_id, position") {
            guard let showId = row["show_id"]?.string, let i = index[showId],
                  let data = row["payload"]?.data,
                  let episode = try? decoder.decode(PodcastEpisode.self, from: data) else {
                skipped += 1
                continue
            }
            shows[i].episodes.append(episode)
        }
        if skipped > 0 {
            Logger.rss.error("SUBROWS load: \(skipped) rows undecodable, skipped")
        }
        return shows
    }

    /// Replaces the stock: the import from the document, in one transaction.
    @discardableResult
    func replaceAll(_ shows: [PodcastShow]) async throws -> Counts {
        try await connection.execute("BEGIN IMMEDIATE")
        do {
            try await connection.execute("DELETE FROM episode")
            try await connection.execute("DELETE FROM show")
            let counts = try await write(PodcastRowDiff.all(shows))
            try await connection.execute("COMMIT")
            return counts
        } catch {
            try? await connection.execute("ROLLBACK")
            throw error
        }
    }

    /// Applies a diff in one transaction. Removed shows take their episodes
    /// with them (cascade).
    @discardableResult
    func apply(_ diff: PodcastRowDiff) async throws -> Counts {
        guard !diff.isEmpty else { return Counts(shows: 0, episodes: 0) }
        try await connection.execute("BEGIN IMMEDIATE")
        do {
            let counts = try await write(diff)
            try await connection.execute("COMMIT")
            return counts
        } catch {
            try? await connection.execute("ROLLBACK")
            throw error
        }
    }

    /// The statements of a diff, inside a transaction the caller owns.
    /// Returns how many rows were written (upserted); removals are not
    /// counted in it.
    private func write(_ diff: PodcastRowDiff) async throws -> Counts {
        let encoder = JSONEncoder()
        for id in diff.showsRemoved {
            try await connection.run("DELETE FROM show WHERE id = ?", [.text(id)])
        }
        for guid in diff.episodesRemoved {
            try await connection.run("DELETE FROM episode WHERE guid = ?", [.text(guid)])
        }
        for row in diff.showsUpserted {
            try await connection.run("""
                INSERT INTO show (id, position, payload) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, payload = excluded.payload
                """, [.text(row.show.id), .integer(Int64(row.position)), .blob(try encoder.encode(row.show))])
        }
        for row in diff.episodesUpserted {
            try await connection.run("""
                INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(guid) DO UPDATE SET show_id = excluded.show_id, position = excluded.position,
                    pub_date = excluded.pub_date, payload = excluded.payload
                """, [.text(row.episode.guid), .text(row.showId), .integer(Int64(row.position)),
                      .real(row.episode.pubDate), .blob(try encoder.encode(row.episode))])
        }
        return Counts(shows: diff.showsUpserted.count, episodes: diff.episodesUpserted.count)
    }
}
