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
///
/// The shownotes are the exception: they stand in `episode_note`, one row
/// per guid, and are read when an episode is opened (`notes(guid:)`), so
/// the start reads and holds no notes. The table has no foreign key: a
/// hand-over removes the episode rows of the account that leaves, and its
/// notes stay for its return. A payload that still carries notes (a row
/// written by an older build, a raw row carried back) gives them to the
/// table before it is overwritten or removed, never over a newer note.
actor PodcastRowStore {
    static let family = "podcast"
    /// 2: the shownotes moved from the episode payload to `episode_note`.
    static let schemaVersion = 2

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
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS episode_note (
                guid TEXT PRIMARY KEY,
                notes TEXT NOT NULL
            )
            """)
        for statement in Self.noteRescue { try await connection.execute(statement) }
        let version = try await connection.schemaVersion(of: Self.family)
        if version < 2 {
            // One transaction: the notes leave the payloads, and the version
            // says so, or neither happens.
            try await connection.transaction(Self.notesMove)
        }
        if version < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    /// The shownotes inside a payload, NULL when it carries none. The
    /// payload is a blob of JSON text; the cast keeps the JSON functions
    /// from reading it as their binary form. A payload that is no JSON (a
    /// later build's form, a broken row) carries no notes: the JSON
    /// functions raise on it, and a raise inside a trigger fails the write
    /// that removes or replaces the row.
    private static func notesIn(_ payload: String) -> String {
        "CASE WHEN json_valid(CAST(\(payload) AS TEXT)) THEN json_extract(CAST(\(payload) AS TEXT), '$.description') END"
    }

    /// A payload that still carries notes gives them to the table before it
    /// is overwritten or removed, and never over a note that stands. The
    /// triggers are made anew at every open, so a database keeps no older
    /// form of them.
    static let noteRescue: [String] = [
        "DROP TRIGGER IF EXISTS episode_note_rescue_update",
        "DROP TRIGGER IF EXISTS episode_note_rescue_delete",
        """
        CREATE TRIGGER episode_note_rescue_update BEFORE UPDATE OF payload ON episode
        WHEN \(notesIn("OLD.payload")) IS NOT NULL AND \(notesIn("OLD.payload")) != ''
        BEGIN
            INSERT OR IGNORE INTO episode_note (guid, notes) VALUES (OLD.guid, \(notesIn("OLD.payload")));
        END
        """,
        """
        CREATE TRIGGER episode_note_rescue_delete BEFORE DELETE ON episode
        WHEN \(notesIn("OLD.payload")) IS NOT NULL AND \(notesIn("OLD.payload")) != ''
        BEGIN
            INSERT OR IGNORE INTO episode_note (guid, notes) VALUES (OLD.guid, \(notesIn("OLD.payload")));
        END
        """,
    ]

    /// Version 1 to 2: every payload's notes into the table, then out of
    /// the payload, then the version.
    static let notesMove: [SQLiteConnection.Statement] = [
        .init("""
            INSERT OR IGNORE INTO episode_note (guid, notes)
            SELECT guid, \(notesIn("payload")) FROM episode
            WHERE \(notesIn("payload")) IS NOT NULL AND \(notesIn("payload")) != ''
            """),
        .init("""
            UPDATE episode SET payload = CAST(json_remove(CAST(payload AS TEXT), '$.description') AS BLOB)
            WHERE CASE WHEN json_valid(CAST(payload AS TEXT))
                       THEN json_type(CAST(payload AS TEXT), '$.description') IS NOT NULL ELSE 0 END
            """),
        .init("INSERT INTO schema (family, version) VALUES (?, 2) ON CONFLICT(family) DO UPDATE SET version = excluded.version",
              [.text(family)]),
    ]

    /// The shownotes of one episode: the table's, else what an older
    /// payload still carries; nil when there are none.
    func notes(guid: String) async throws -> String? {
        if let notes = try await connection.query("SELECT notes FROM episode_note WHERE guid = ?", [.text(guid)])
            .first?["notes"]?.string {
            return notes
        }
        guard let data = try await connection.query("SELECT payload FROM episode WHERE guid = ?", [.text(guid)])
            .first?["payload"]?.data else { return nil }
        return (try? JSONDecoder().decode(PodcastEpisode.self, from: data))?.description
    }

    /// The statements that write shownotes: a fresh text replaces the one
    /// that stands.
    nonisolated static func noteStatements(_ notes: [String: String]) -> [SQLiteConnection.Statement] {
        notes.sorted { $0.key < $1.key }.map { guid, text in
            .init("""
                INSERT INTO episode_note (guid, notes) VALUES (?, ?)
                ON CONFLICT(guid) DO UPDATE SET notes = excluded.notes WHERE notes IS NOT excluded.notes
                """, [.text(guid), .text(text)])
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
        try await loadAllCounted().shows
    }

    /// The same load, with the count of rows that did not decode: a store
    /// that finds skipped rows treats its rows as unknown, never as empty.
    func loadAllCounted() async throws -> (shows: [PodcastShow], skipped: Int) {
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
        return (shows, skipped)
    }

    /// Rows this build cannot decode, as stored: a show row whose payload
    /// does not decode, every episode row of such a show, and an episode row
    /// whose own payload does not decode. A hand-over carries them as they
    /// are, so a later build reads them under the account they belong to.
    nonisolated struct RawRows: Codable, Equatable, Sendable {
        struct Show: Codable, Equatable, Sendable { var id: String; var position: Int; var payload: Data }
        struct Episode: Codable, Equatable, Sendable {
            var guid: String; var showId: String; var position: Int; var pubDate: Double; var payload: Data
        }
        var shows: [Show] = []
        var episodes: [Episode] = []
        var isEmpty: Bool { shows.isEmpty && episodes.isEmpty }

        /// The rows whose show stands: a raw show of these rows, or one of
        /// `shows`. An episode whose show is gone (unsubscribed since) has
        /// no place; inserted, it breaks the foreign key and with it the
        /// whole write.
        func standing(under shows: Set<String>) -> RawRows {
            let present = shows.union(self.shows.map(\.id))
            return RawRows(shows: self.shows, episodes: episodes.filter { present.contains($0.showId) })
        }
    }

    /// The undecodable rows at this moment, through a reader of its own.
    /// EMPTY when the tables do not exist; THROWS when the read fails.
    nonisolated static func undecodedNow(reader: SQLiteReader) throws -> RawRows {
        let tables = Set(try reader.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.string })
        guard tables.contains("show") else { return RawRows() }
        let decoder = JSONDecoder()
        var raw = RawRows()
        var rawShows: Set<String> = []
        for row in try reader.query("SELECT id, position, payload FROM show") {
            guard let id = row["id"]?.string, let data = row["payload"]?.data else { continue }
            do {
                _ = try decoder.decode(PodcastShow.self, from: data)
            } catch {
                raw.shows.append(.init(id: id, position: Int(row["position"]?.int64 ?? 0), payload: data))
                rawShows.insert(id)
            }
        }
        guard tables.contains("episode") else { return raw }
        for row in try reader.query("SELECT guid, show_id, position, pub_date, payload FROM episode") {
            guard let guid = row["guid"]?.string, let showId = row["show_id"]?.string,
                  let data = row["payload"]?.data else { continue }
            let episode = RawRows.Episode(guid: guid, showId: showId, position: Int(row["position"]?.int64 ?? 0),
                                          pubDate: row["pub_date"]?.double ?? 0, payload: data)
            if rawShows.contains(showId) {
                raw.episodes.append(episode)
                continue
            }
            do {
                _ = try decoder.decode(PodcastEpisode.self, from: data)
            } catch {
                raw.episodes.append(episode)
            }
        }
        raw.shows.sort { $0.id < $1.id }
        raw.episodes.sort { $0.guid < $1.guid }
        return raw
    }

    /// The statements that carry raw rows at a hand-over, after the diff of
    /// the same write: `leaving` leave the tables, `coming` come back as
    /// they were (shows before their episodes), never over a show or an
    /// episode the new stock holds (`keptShows`, `keptEpisodes`). An
    /// unread episode may stand under a show that is read: it moves by its
    /// own guid, not by its show.
    nonisolated static func carriedRows(leaving: RawRows, coming: RawRows, keptShows: Set<String>,
                                        keptEpisodes: Set<String>) -> [SQLiteConnection.Statement] {
        var out: [SQLiteConnection.Statement] = []
        for episode in leaving.episodes where !keptEpisodes.contains(episode.guid) {
            out.append(.init("DELETE FROM episode WHERE guid = ?", [.text(episode.guid)]))
        }
        for show in leaving.shows where !keptShows.contains(show.id) {
            out.append(.init("DELETE FROM show WHERE id = ?", [.text(show.id)]))
        }
        for show in coming.shows where !keptShows.contains(show.id) {
            out.append(.init("INSERT OR REPLACE INTO show (id, position, payload) VALUES (?, ?, ?)",
                             [.text(show.id), .integer(Int64(show.position)), .blob(show.payload)]))
        }
        // Only an episode whose show stands after this write: one of the new
        // stock or a raw show that comes back with it.
        for episode in coming.standing(under: keptShows).episodes where !keptEpisodes.contains(episode.guid) {
            out.append(.init("""
                INSERT OR REPLACE INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)
                """, [.text(episode.guid), .text(episode.showId), .integer(Int64(episode.position)),
                      .real(episode.pubDate), .blob(episode.payload)]))
        }
        return out
    }

    /// Replaces the stock: the import from the document, in one transaction.
    @discardableResult
    func replaceAll(_ shows: [PodcastShow]) async throws -> Counts {
        let diff = PodcastRowDiff.all(shows)
        let statements = [SQLiteConnection.Statement("DELETE FROM episode"), SQLiteConnection.Statement("DELETE FROM show")]
            + (try Self.statements(diff))
        try await connection.transaction(statements)
        return Counts(shows: diff.showsUpserted.count, episodes: diff.episodesUpserted.count)
    }

    /// Applies a diff in one transaction. Removed shows take their episodes
    /// with them (cascade). `also` lands in the same transaction (a mark
    /// that must land with these rows, `OwnerMark`); `also` alone is
    /// written too. `notes` are the shownotes taken from the stock
    /// (`PodcastNotes.split`), written with the rows that carry their stamps.
    @discardableResult
    func apply(_ diff: PodcastRowDiff, notes: [String: String] = [:],
               also: [SQLiteConnection.Statement] = []) async throws -> Counts {
        guard !diff.isEmpty || !notes.isEmpty || !also.isEmpty else { return Counts(shows: 0, episodes: 0) }
        try await connection.transaction(try Self.statements(diff) + Self.noteStatements(notes) + also)
        return Counts(shows: diff.showsUpserted.count, episodes: diff.episodesUpserted.count)
    }

    /// The statements of a diff, encoded up front so the transaction on
    /// the connection runs without a suspension.
    private nonisolated static func statements(_ diff: PodcastRowDiff) throws -> [SQLiteConnection.Statement] {
        let encoder = JSONEncoder()
        var out: [SQLiteConnection.Statement] = []
        for id in diff.showsRemoved {
            out.append(.init("DELETE FROM show WHERE id = ?", [.text(id)]))
        }
        for guid in diff.episodesRemoved {
            out.append(.init("DELETE FROM episode WHERE guid = ?", [.text(guid)]))
        }
        for row in diff.showsUpserted {
            out.append(.init("""
                INSERT INTO show (id, position, payload) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, payload = excluded.payload
                """, [.text(row.show.id), .integer(Int64(row.position)), .blob(try encoder.encode(row.show))]))
        }
        for row in diff.episodesUpserted {
            out.append(.init("""
                INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(guid) DO UPDATE SET show_id = excluded.show_id, position = excluded.position,
                    pub_date = excluded.pub_date, payload = excluded.payload
                """, [.text(row.episode.guid), .text(row.showId), .integer(Int64(row.position)),
                      .real(row.episode.pubDate), .blob(try encoder.encode(row.episode))]))
        }
        return out
    }
}
