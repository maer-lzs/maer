// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import SQLite3

/// Import of podcast subscriptions (and, from Apple Podcasts, also
/// progress/played) from external sources. Two paths:
///
/// 1. **OPML** — the open standard that (almost) every podcast app exports.
///    Holds only the feed URLs, no progress.
/// 2. **Apple Podcasts** — Apple offers no export and no API. The only way to
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
        let parser = OPMLParser()
        return parser.parse(data)
    }

    // MARK: - Apple Podcasts (MTLibrary.sqlite)

    /// A progress record from Apple Podcasts, matched via the enclosure URL
    /// (which is also in our RSS feed).
    nonisolated struct AppleProgress: Sendable {
        let enclosureURL: String
        let playhead: Double   // seconds
        let duration: Double   // seconds (0 if unknown)
        let isPlayed: Bool
        /// The episode title, for the fallback match — enclosure URLs drift
        /// (CDN tokens, host moves), and a drifted URL matches nothing.
        var title: String? = nil
        /// When Apple last recorded playback, in milliseconds since 1970 —
        /// the entry's OWN moment. Stamping "now" instead made every imported
        /// entry younger than everything it met, so it won merges it had no
        /// business winning.
        var timestampMs: Double? = nil
    }

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

    /// **Better-wins, against LOCAL too.** The import used to write raw
    /// two-value literals with a fresh stamp unconditionally over the local
    /// state — the dedup rule (played beats unplayed, then the further
    /// position) existed only WITHIN the Apple data, never against what this
    /// device already knew. Two finished marks were measurably destroyed that
    /// way. `nil` means the local entry is the better knowledge and stays.
    ///
    /// The entry goes through `advancing`, so an existing reference point
    /// survives, and it carries the APPLE moment where the store states one —
    /// an import is old knowledge and must not beat newer entries elsewhere.
    nonisolated static func adoptedEntry(local: [Double]?,
                                         playhead: Double,
                                         duration: Double,
                                         isPlayed: Bool,
                                         timestampMs: Double?,
                                         nowMs: Double) -> [Double]? {
        // Apple resets state AND playhead when an episode completes — a
        // played episode without a known duration still deserves its mark,
        // via the same sentinel every other "played without duration" uses.
        let time: Double
        if isPlayed {
            time = duration > 0 ? max(duration, playhead) : ProgressMark.playedSentinel
        } else {
            time = playhead
        }
        guard time > 1 else { return nil }
        let localPlayed = local.map { ProgressMark.isPlayed(stored: $0, currentDuration: duration) } ?? false
        if localPlayed, !isPlayed { return nil }          // never reset finished
        if localPlayed, isPlayed { return nil }           // nothing to gain
        if !isPlayed, let local, let position = local.first, position >= time { return nil }
        return ProgressMark.advancing(local, position: time, duration: duration,
                                      nowMs: timestampMs ?? nowMs)
    }

    nonisolated struct AppleLibrary: Sendable {
        let feedURLs: [String]
        let progress: [AppleProgress]
        /// Subscribed shows that cannot be imported because they expose no
        /// public RSS feed (paid/Apple-exclusive subscriptions). Surfaced as a
        /// hint instead of being swallowed silently.
        var unimportablePaidCount = 0
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

    /// Reads the Apple Podcasts database read-only. `nil` on open error. Missing
    /// columns/tables do NOT abort — just less is returned (personal/best-effort,
    /// see the type doc).
    nonisolated static func readAppleLibrary(at url: URL) -> AppleLibrary? {
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

        // Feeds: only ACTIVE (subscribed/followed) shows (S21) — not the whole
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
        var progress: [AppleProgress] = []
        if let urlCol = firstPresent(["ZENCLOSUREURL", "ZASSETURL", "ZWEBPAGEURL"], in: episodeCols) {
            let playheadCol = firstPresent(["ZPLAYHEAD", "ZLASTPLAYHEADPOSITION", "ZPROGRESS"], in: episodeCols)
            let durationCol = firstPresent(["ZDURATION", "ZASSETDURATION"], in: episodeCols)
            let playedCol = firstPresent(["ZPLAYSTATE", "ZISPLAYED", "ZPLAYED"], in: episodeCols)
            // The play COUNT is the second witness, and the decisive one:
            // cross-tabulated on a real store, every hand-marked episode had
            // state 2 and count 0, every listened-through one state 0 and
            // count 1 — Apple resets state and playhead on completion. The
            // state alone missed 1,163 finished episodes.
            let playCountCol = firstPresent(["ZPLAYCOUNT", "ZPLAYEDCOUNT", "ZTIMESPLAYED"], in: episodeCols)
            // Measured on the real store: ZPLAYSTATELASTMODIFIEDDATE is
            // filled for BOTH played classes (hand-marked and listened
            // through), ZLASTDATEPLAYED only for the listened-through ones.
            // So both columns are read PER ROW: the playback date where it
            // exists, the state-change date otherwise — practically nothing
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
                // Apple: ZPLAYSTATE == 2 is "marked played" — OR the episode
                // was actually listened through, which only the count knows.
                let stateSaysPlayed = (playedCol == "ZPLAYSTATE") ? stateRaw >= 2 : stateRaw > 0
                let isPlayed = stateSaysPlayed || playCount > 0
                if playhead > 1 || isPlayed {
                    progress.append(AppleProgress(
                        enclosureURL: enclosure, playhead: playhead, duration: duration,
                        isPlayed: isPlayed, title: title, timestampMs: timestamp
                    ))
                }
            }
        }

        return AppleLibrary(feedURLs: feedURLs, progress: progress, unimportablePaidCount: paidCount)
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

/// Minimal OPML parser: collects all `xmlUrl` attributes (feed URLs).
/// `nonisolated` so it can be created from the nonisolated `parseOPML` (the
/// project default is otherwise MainActor isolation).
private nonisolated final class OPMLParser: NSObject, XMLParserDelegate {
    private var feedURLs: [String] = []

    nonisolated func parse(_ data: Data) -> [String]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // A failed parse used to be ignored — everything collected before
        // the error leaked out as a silent partial import.
        guard parser.parse() else { return nil }
        return feedURLs
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                            qualifiedName qName: String?, attributes attrs: [String: String]) {
        guard el == "outline" else { return }
        if let url = attrs["xmlUrl"] ?? attrs["xmlURL"], !url.isEmpty {
            feedURLs.append(url)
        }
    }
}
