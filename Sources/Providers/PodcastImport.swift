import Foundation
import SQLite3

/// Import von Podcast-Abos (und, aus Apple Podcasts, auch Fortschritt/Gehört)
/// aus externen Quellen. Zwei Wege:
///
/// 1. **OPML** — der offene Standard, den (fast) jede Podcast-App exportiert.
///    Enthält nur die Feed-URLs, keinen Fortschritt.
/// 2. **Apple Podcasts** — Apple bietet keinen Export und keine API. Der einzige
///    Weg an Abos + Fortschritt + Gehört ist die private Core-Data-Datenbank
///    `MTLibrary.sqlite` vom Mac (~/Library/Group Containers/…/Documents). Wird
///    hier read-only + defensiv gegen Schema-Änderungen gelesen; bricht eine
///    Apple-Version das Schema, liefert der Import eben nur, was er findet.
enum PodcastImport {

    // MARK: - OPML

    /// Alle `xmlUrl`-Feeds aus einer OPML-Datei (Reihenfolge wie in der Datei).
    nonisolated static func parseOPML(_ data: Data) -> [String] {
        let parser = OPMLParser()
        return parser.parse(data)
    }

    // MARK: - Apple Podcasts (MTLibrary.sqlite)

    /// Ein Fortschritts-Datensatz aus Apple Podcasts, zugeordnet über die
    /// Enclosure-URL (die auch in unserem RSS-Feed steht).
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

    /// Liest die Apple-Podcasts-Datenbank read-only aus. `nil` bei Öffnen-Fehler.
    /// Fehlende Spalten/Tabellen führen NICHT zum Abbruch — es wird nur weniger
    /// zurückgegeben (personal/best-effort, siehe Typ-Doku).
    nonisolated static func readAppleLibrary(at url: URL) -> AppleLibrary? {
        var db: OpaquePointer?
        // `immutable=1`: die kopierte Datei ändert sich nicht → SQLite liest
        // ohne Sperren/WAL-Seitendateien (die beim Kopieren meist fehlen) und
        // schreibt nie in die fremde Datei. URI aus dem file:// absoluteString,
        // damit Sonderzeichen im Pfad korrekt kodiert sind.
        let uri = url.absoluteString + "?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let podcastCols = columns(db, table: "ZMTPODCAST")
        let episodeCols = columns(db, table: "ZMTEPISODE")

        // Feeds: alle Shows mit Feed-URL (Abo-Flag nicht überall gesetzt →
        // wir nehmen jede Show, die eine Feed-URL hat).
        var feedURLs: [String] = []
        if podcastCols.contains("ZFEEDURL") {
            for row in query(db, "SELECT ZFEEDURL FROM ZMTPODCAST WHERE ZFEEDURL IS NOT NULL") {
                if let feed = row[0] { feedURLs.append(feed) }
            }
        }

        // Fortschritt/Gehört je Episode über die Enclosure-URL.
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
                // Apple: ZPLAYSTATE == 2 bedeutet „gehört"; sonst 1/0. Bei einem
                // reinen Bool-Feld (ZISPLAYED/ZPLAYED) zählt jeder Wert > 0.
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

    // MARK: - SQLite-Helfer (defensiv, ohne Fremd-Abhängigkeit)

    /// Spaltennamen einer Tabelle (leer, wenn Tabelle fehlt).
    private nonisolated static func columns(_ db: OpaquePointer, table: String) -> Set<String> {
        var cols: Set<String> = []
        for row in query(db, "PRAGMA table_info(\(table))") {
            if let name = row[1] { cols.insert(name) }  // name = zweite Spalte
        }
        return cols
    }

    private nonisolated static func firstPresent(_ candidates: [String], in cols: Set<String>) -> String? {
        candidates.first { cols.contains($0) }
    }

    /// Führt ein SELECT aus und gibt jede Zeile als String-Array (nil = NULL).
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
