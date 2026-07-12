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

    /// Alle `xmlUrl`-Feeds aus einer OPML-Datei (Reihenfolge wie in der Datei).
    nonisolated static func parseOPML(_ data: Data) -> [String] {
        let parser = OPMLParser()
        return parser.parse(data)
    }

    // MARK: - Apple Podcasts (MTLibrary.sqlite)

    /// A progress record from Apple Podcasts, matched via the enclosure URL
    /// (which is also in our RSS feed).
    nonisolated struct AppleProgress: Sendable {
        let enclosureURL: String
        let playhead: Double   // Sekunden
        let duration: Double   // Sekunden (0 wenn unbekannt)
        let isPlayed: Bool
    }

    nonisolated struct AppleLibrary: Sendable {
        let feedURLs: [String]
        let progress: [AppleProgress]
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

        // Feeds: all shows with a feed URL (the subscription flag is not always
        // set → we take every show that has a feed URL).
        var feedURLs: [String] = []
        if podcastCols.contains("ZFEEDURL") {
            for row in query(db, "SELECT ZFEEDURL FROM ZMTPODCAST WHERE ZFEEDURL IS NOT NULL") {
                if let feed = row[0] { feedURLs.append(feed) }
            }
        }

        // Progress/played per episode via the enclosure URL.
        var progress: [AppleProgress] = []
        if let urlCol = firstPresent(["ZENCLOSUREURL", "ZASSETURL", "ZWEBPAGEURL"], in: episodeCols) {
            let playheadCol = firstPresent(["ZPLAYHEAD", "ZLASTPLAYHEADPOSITION", "ZPROGRESS"], in: episodeCols)
            let durationCol = firstPresent(["ZDURATION", "ZASSETDURATION"], in: episodeCols)
            let playedCol = firstPresent(["ZPLAYSTATE", "ZISPLAYED", "ZPLAYED"], in: episodeCols)

            var selected = [urlCol]
            if let playheadCol { selected.append(playheadCol) }
            if let durationCol { selected.append(durationCol) }
            if let playedCol { selected.append(playedCol) }

            let sql = "SELECT \(selected.joined(separator: ", ")) FROM ZMTEPISODE WHERE \(urlCol) IS NOT NULL"
            for row in query(db, sql) {
                guard let enclosure = row[0], !enclosure.isEmpty else { continue }
                var idx = 1
                let playhead = playheadCol != nil ? Double(row[idx] ?? "") ?? 0 : 0
                if playheadCol != nil { idx += 1 }
                let duration = durationCol != nil ? Double(row[idx] ?? "") ?? 0 : 0
                if durationCol != nil { idx += 1 }
                // Apple: ZPLAYSTATE == 2 means "played"; otherwise 1/0. For a
                // plain bool field (ZISPLAYED/ZPLAYED) any value > 0 counts.
                var isPlayed = false
                if playedCol != nil {
                    let raw = Double(row[idx] ?? "") ?? 0
                    isPlayed = (playedCol == "ZPLAYSTATE") ? raw >= 2 : raw > 0
                }
                if playhead > 1 || isPlayed {
                    progress.append(AppleProgress(
                        enclosureURL: enclosure, playhead: playhead, duration: duration, isPlayed: isPlayed
                    ))
                }
            }
        }

        return AppleLibrary(feedURLs: feedURLs, progress: progress)
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

/// Minimaler OPML-Parser: sammelt alle `xmlUrl`-Attribute (Feed-URLs).
/// `nonisolated`, damit er aus dem nonisolated `parseOPML` erzeugt werden kann
/// (Projekt-Default ist sonst MainActor-Isolation).
private nonisolated final class OPMLParser: NSObject, XMLParserDelegate {
    private var feedURLs: [String] = []

    nonisolated func parse(_ data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
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
