// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import SQLite3

/// Import of podcast subscriptions (and, from Apple Podcasts, also
/// progress/played) from external sources. Two paths:
///
/// 1. **OPML**. The open standard that (almost) every podcast app exports.
///    Holds only the feed URLs, no progress.
/// 2. **Apple Podcasts**. Apple offers no export and no API. The only way to
///    subscriptions + progress + played is the private Core Data database
///    `MTLibrary.sqlite` from the Mac (~/Library/Group Containers/…/Documents).
///    Read here read-only + defensively against schema changes; if an Apple
///    version breaks the schema, the import just returns what it finds.
enum PodcastImport {

    // MARK: - OPML

    /// All `xmlUrl` feeds from an OPML file (order as in the file).
    /// `nil` when the XML is not well-formed: a partial
    /// list from a broken file must fail visibly, not import silently.
    nonisolated static func parseOPML(_ data: Data) -> [String]? {
        // The one OPML reader lives in the core layer; a plain list is its
        // extended form without episode outlines.
        OvercastOPML.parse(data)?.feedURLs
    }

    // MARK: - Apple Podcasts (MTLibrary.sqlite)

    /// Apple stores dates on the Core-Data epoch (seconds since 2001-01-01).
    /// Converted defensively: a value that does not land in the plausible
    /// window is discarded rather than guessed at.
    nonisolated static func appleTimestampMs(_ raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        let unixSeconds = raw + 978_307_200
        // Podcasts app exists since 2012; a moment before that or in the
        // far future is not a playback date.
        guard unixSeconds > 1_325_376_000, unixSeconds < 4_102_444_800 else { return nil }
        return unixSeconds * 1000
    }

    /// One Apple Podcasts show as far as import selection cares (S21).
    nonisolated struct AppleShow: Sendable, Equatable {
        let feedURL: String?
        let isSubscribed: Bool
    }

    /// Pure import selection (S21, testable): only ACTIVE (subscribed/followed)
    /// shows are taken; a subscribed show WITHOUT a public feed URL is a
    /// paid/exclusive one that can't be imported and is counted for a hint.
    /// Unsubscribed historical shows are ignored entirely.
    nonisolated static func selectImportable(_ shows: [AppleShow]) -> (feeds: [String], paidUnimportable: Int) {
        var feeds: [String] = []
        var paid = 0
        for show in shows where show.isSubscribed {
            if let feed = show.feedURL, !feed.isEmpty { feeds.append(feed) } else { paid += 1 }
        }
        return (feeds, paid)
    }

    /// Reads one foreign source into the common library. nil when the
    /// file cannot be read as that source; the caller shows the reason.
    /// The SQLite read runs off the main actor, it can take a while for a
    /// large database; the caller's security-scoped access applies
    /// process-wide.
    nonisolated static func readLibrary(source: ForeignSource, at url: URL) async -> ForeignLibrary? {
        switch source {
        case .opml:
            do {
                return OvercastOPML.parse(try Data(contentsOf: url))
            } catch {
                Logger.rss.error("OPML import: file unreadable: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .applePodcasts:
            return await Task.detached(priority: .userInitiated) {
                readAppleLibrary(at: url)
            }.value
        }
    }

    /// Reads the Apple Podcasts database read-only. `nil` on open error. Missing
    /// columns/tables do NOT abort. Just less is returned (personal/best-effort,
    /// see the type doc). Rows carry no feed: the episode table is read
    /// without a join, so the ladder searches every show for them.
    nonisolated static func readAppleLibrary(at url: URL) -> ForeignLibrary? {
        var db: OpaquePointer?
        // `immutable=1`: the copied file does not change → SQLite reads without
        // locks/WAL side files (usually missing after copying) and never writes
        // to the foreign file. URI from the file:// absoluteString so special
        // characters in the path are encoded correctly.
        let uri = url.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let podcastCols = columns(db, table: "ZMTPODCAST")
        let episodeCols = columns(db, table: "ZMTEPISODE")

        // Feeds: only ACTIVE (subscribed/followed) shows (S21). Not the whole
        // historical list. A subscribed show without a public feed URL is a
        // paid/Apple-exclusive one: counted for a hint, not imported. Older
        // schemas without a follow flag fall back to taking every show with a
        // feed URL (the paid count is then unreliable → suppressed).
        var feedURLs: [String] = []
        var paidCount = 0
        if podcastCols.contains("ZFEEDURL") {
            let subCol = firstPresent(
                ["ZSUBSCRIBED", "ZISSUBSCRIBED", "ZFOLLOWING", "ZISFOLLOWED", "ZFOLLOWED"],
                in: podcastCols)
            let selectCols = subCol.map { "ZFEEDURL, \($0)" } ?? "ZFEEDURL"
            var shows: [AppleShow] = []
            for row in query(db, "SELECT \(selectCols) FROM ZMTPODCAST") {
                // No follow column (old schema) → treat all as subscribed (prior behaviour).
                let subscribed = subCol == nil ? true : (Double(row[1] ?? "") ?? 0) > 0
                shows.append(AppleShow(feedURL: row[0], isSubscribed: subscribed))
            }
            let selected = selectImportable(shows)
            feedURLs = selected.feeds
            paidCount = subCol != nil ? selected.paidUnimportable : 0
        }

        // Progress/played per episode via the enclosure URL.
        var states: [ForeignListeningState] = []
        if let urlCol = firstPresent(["ZENCLOSUREURL", "ZASSETURL", "ZWEBPAGEURL"], in: episodeCols) {
            let playheadCol = firstPresent(["ZPLAYHEAD", "ZLASTPLAYHEADPOSITION", "ZPROGRESS"], in: episodeCols)
            let durationCol = firstPresent(["ZDURATION", "ZASSETDURATION"], in: episodeCols)
            let playedCol = firstPresent(["ZPLAYSTATE", "ZISPLAYED", "ZPLAYED"], in: episodeCols)
            // The play COUNT is the second witness, and the decisive one:
            // cross-tabulated on a real store, every hand-marked episode had
            // state 2 and count 0, every listened-through one state 0 and
            // count 1. Apple resets state and playhead on completion. The
            // state alone missed 1,163 finished episodes.
            let playCountCol = firstPresent(["ZPLAYCOUNT", "ZPLAYEDCOUNT", "ZTIMESPLAYED"], in: episodeCols)
            // Measured on the real store: ZPLAYSTATELASTMODIFIEDDATE is
            // filled for BOTH played classes (hand-marked and listened
            // through), ZLASTDATEPLAYED only for the listened-through ones.
            // So both columns are read PER ROW: the playback date where it
            // exists, the state-change date otherwise. Practically nothing
            // falls back to the import moment.
            let playedDateCol = firstPresent(["ZLASTDATEPLAYED"], in: episodeCols)
            let stateDateCol = firstPresent(["ZPLAYSTATELASTMODIFIEDDATE"], in: episodeCols)
            let titleCol = firstPresent(["ZTITLE", "ZCLEANEDTITLE"], in: episodeCols)

            var selected = [urlCol]
            if let playheadCol { selected.append(playheadCol) }
            if let durationCol { selected.append(durationCol) }
            if let playedCol { selected.append(playedCol) }
            if let playCountCol { selected.append(playCountCol) }
            if let playedDateCol { selected.append(playedDateCol) }
            if let stateDateCol { selected.append(stateDateCol) }
            if let titleCol { selected.append(titleCol) }

            let sql = "SELECT \(selected.joined(separator: ", ")) FROM ZMTEPISODE WHERE \(urlCol) IS NOT NULL"
            for row in query(db, sql) {
                guard let enclosure = row[0], !enclosure.isEmpty else { continue }
                var idx = 1
                func next(_ col: String?) -> String? {
                    guard col != nil else { return nil }
                    defer { idx += 1 }
                    return idx < row.count ? row[idx] : nil
                }
                let playhead = next(playheadCol).flatMap(Double.init) ?? 0
                let duration = next(durationCol).flatMap(Double.init) ?? 0
                let stateRaw = next(playedCol).flatMap(Double.init) ?? 0
                let playCount = next(playCountCol).flatMap(Double.init) ?? 0
                let playedDate = appleTimestampMs(next(playedDateCol).flatMap(Double.init))
                let stateDate = appleTimestampMs(next(stateDateCol).flatMap(Double.init))
                let timestamp = playedDate ?? stateDate
                let title = next(titleCol)
                // Apple: ZPLAYSTATE == 2 is "marked played". OR the episode
                // was actually listened through, which only the count knows.
                let stateSaysPlayed = (playedCol == "ZPLAYSTATE") ? stateRaw >= 2 : stateRaw > 0
                let isPlayed = stateSaysPlayed || playCount > 0
                if playhead > 1 || isPlayed {
                    states.append(ForeignListeningState(
                        feedURL: nil, episodeGUID: nil, enclosureURL: enclosure,
                        episodeLink: nil, episodeTitle: title,
                        position: playhead, duration: duration > 0 ? duration : nil,
                        finished: isPlayed, stampedAt: timestamp))
                }
            }
        }

        return ForeignLibrary(feedURLs: feedURLs, states: states, unimportablePaidCount: paidCount)
    }

    // MARK: - SQLite helpers (defensive, no third-party dependency)

    /// Column names of a table (empty if the table is missing).
    private nonisolated static func columns(_ db: OpaquePointer, table: String) -> Set<String> {
        var cols: Set<String> = []
        for row in query(db, "PRAGMA table_info(\(table))") {
            if let name = row[1] { cols.insert(name) }  // name = second column
        }
        return cols
    }

    private nonisolated static func firstPresent(_ candidates: [String], in cols: Set<String>) -> String? {
        candidates.first { cols.contains($0) }
    }

    /// Runs a SELECT and returns each row as a string array (nil = NULL).
    private nonisolated static func query(_ db: OpaquePointer, _ sql: String) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [String?] = []
            for i in 0..<count {
                if let c = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: c))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }
}
