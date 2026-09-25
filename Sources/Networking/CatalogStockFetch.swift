// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// How a kept stock is fetched: over the MASS routes only, never over the
/// paging APIs the surfaces use.
///
/// archive.org has a scrape endpoint with a cursor. Measured: 10.000
/// entries in 3,6 s, so the largest collection (187.031) takes 19 calls and
/// about 69 s, and all five together 38 calls in 2,3 minutes. The paging
/// search would be hundreds of calls for the same thing.
///
/// Gutenberg has an official catalogue dump. Measured: it does NOT carry the
/// download counts, so the popularity ORDER stays with the service; what the
/// dump gives is the stock itself, 1.114 audio works in 0,23 MB.
nonisolated enum CatalogStockFetch {
    /// Exactly the fields the stock keeps. Asking for more would be paid for
    /// on every entry of every collection.
    static let scrapeFields = "identifier,title,creator,subject,downloads,licenseurl,year"

    /// The endpoint caps a call at 10.000, and that is what we ask for: the
    /// call costs the same either way, and fewer calls is politer.
    static let scrapeCount = 10_000

    struct Slice: Sendable {
        var entries: [CatalogStockEntry]
        var cursor: String?
        var total: Int
    }

    private struct ScrapeResponse: Decodable {
        struct Item: Decodable {
            let identifier: String?
            let title: ArchiveStringList?
            let creator: ArchiveStringList?
            let subject: ArchiveStringList?
            let downloads: Int?
            let licenseurl: ArchiveStringList?
            let year: ArchiveStringList?
        }
        let items: [Item]
        let cursor: String?
        let total: Int?
    }

    static func scrapeURL(query: String, cursor: String?) -> URL? {
        var comp = URLComponents(string: "https://archive.org/services/search/v1/scrape")
        comp?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: scrapeFields),
            URLQueryItem(name: "count", value: String(scrapeCount)),
        ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return comp?.url
    }

    /// ONE slice. The caller loops on the cursor, so it can publish progress
    /// between slices instead of going dark for two minutes.
    static func archiveSlice(query: String, cursor: String? = nil) async throws -> Slice {
        guard let url = scrapeURL(query: query, cursor: cursor) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")
        // A mass route answers in seconds, not in the app's usual window.
        request.timeoutInterval = 60
        let (data, http) = try await HTTP.data(for: request, lane: .mass)
        if let http, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, "")
        }
        let decoded = try JSONDecoder().decode(ScrapeResponse.self, from: data)
        return Slice(entries: decoded.items.compactMap(entry(from:)),
                     cursor: decoded.cursor,
                     total: decoded.total ?? decoded.items.count)
    }

    private static func entry(from item: ScrapeResponse.Item) -> CatalogStockEntry? {
        guard let id = item.identifier, let rawTitle = item.title?.first else { return nil }
        // Mojibake the SOURCE stored (measured: 30 archive items carry it
        // in the title itself) is repaired ONCE, here at the door into the
        // stock, so every surface reading the stock is right at once.
        let title = FreeCatalog.repairedMojibake(rawTitle)
        return CatalogStockEntry(id: id,
                                 title: title,
                                 // The creator field carries the SAME stored
                                 // mojibake, and far more of it than the
                                 // title (measured at the source: 30 titles
                                 // against 514 creators over three patterns
                                 // alone). One door, both fields.
                                 creator: item.creator?.first.map(FreeCatalog.repairedMojibake),
                                 subjects: item.subject?.values ?? [],
                                 downloads: item.downloads,
                                 // Absent stays absent. The capsule says
                                 // "rights not stated" and the download path
                                 // stays closed; nothing is guessed here.
                                 licenseurl: item.licenseurl?.first,
                                 year: item.year?.first)
    }

    /// What came in AFTER the watermark. One query per day and collection,
    /// not a second full pull.
    static func archiveSince(query: String, watermark: String) async throws -> Slice {
        try await archiveSlice(query: "\(query) AND publicdate:[\(watermark) TO 9999-12-31]")
    }

    /// The newest publication date in a slice. It becomes the watermark, so
    /// the next fetch asks for what came after it.
    static func watermark(from entries: [CatalogStockEntry], previous: String?) -> String? {
        // The scrape fields do not carry `publicdate` (it would be a field
        // per entry for a value only the newest one needs). The day of the
        // fetch is the honest mark: everything published before it is in.
        let today = ISO8601DateFormatter()
        today.formatOptions = [.withFullDate]
        return entries.isEmpty ? previous : today.string(from: Date())
    }

    // MARK: - Gutenberg

    static let gutenbergDump = URL(string: "https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv")!

    /// The dump, as the stock. Measured on 29.08.: 21,19 MB in 29,5 s
    /// unpacked, against 5,57 MB in 22,3 s packed.
    ///
    /// The packed form would save 15 MB on the wire and cost a gzip decoder
    /// with its header cases. Behind the Wi-Fi gate the seven seconds are
    /// not worth that; if the size ever matters, the packed URL is one line
    /// away and the decoder is the work.
    /// The catalogue dump is ONE 21 MB file, and the host drops the
    /// transfer mid-stream: measured three times in a row on a fast line,
    /// two runs died after 2,3 and 7,4 MB ("transferred a partial file").
    /// One shot therefore fails on a phone more often than it succeeds,
    /// and it fails ALL-OR-NOTHING, which is exactly what the device
    /// reported as "could not be indexed".
    ///
    /// The host states `accept-ranges: bytes`, so the fetch takes the
    /// file in SLICES and resumes at the byte it already holds. gzip was
    /// measured as no help (the host serves the dump uncompressed either
    /// way, and asking for it cost five times the wall clock).
    static let gutenbergSliceBytes = 4 * 1024 * 1024
    static let gutenbergSliceAttempts = 4

    /// What one slice answered, as a VALUE: the bytes and what the
    /// server said about the whole file. Pure, so the completeness rule
    /// below is testable without a network (the first version decided
    /// on the slice LENGTH and had three holes: a legally short 206
    /// booked a torso as the whole stock, a file sized an exact multiple
    /// of the slice ran one request past EOF into a 416, and a host that
    /// ignores Range never ended).
    struct DumpSlice {
        let bytes: Int
        /// Total file size as stated in `content-range: a-b/TOTAL`.
        let statedTotal: Int?
    }

    /// Does this answer REPLACE the body instead of extending it?
    ///
    /// The request always carries a Range header, so a plain 200 is the
    /// host saying "I ignored it, here is the whole file". Appending such
    /// an answer multiplies the file once per round: it carries no
    /// `Content-Range`, so no total is stated, and it is far longer than
    /// a slice, so the short-answer rule never fires either. The body
    /// grew without bound between the two rules that were supposed to
    /// cover it, one of them ending only at a 416 the host never sends.
    ///
    /// Kept apart from the completeness rule on purpose: this answers
    /// "append or replace", that one answers "are we done". One rule
    /// serving two questions is how the previous hole opened.
    static func dumpAnswerReplacesBody(status: Int?) -> Bool { status == 200 }

    /// Is the body complete? The ANSWER decides, never the slice
    /// length: with a stated total, complete means "we hold it all";
    /// without one (a host that ignores Range) a short answer is the
    /// only honest end signal that remains.
    static func dumpIsComplete(held: Int, slice: DumpSlice, sliceSize: Int) -> Bool {
        if let total = slice.statedTotal { return held >= total }
        return slice.bytes < sliceSize
    }

    /// Parses `bytes 0-4194303/21196613`. nil when the header is absent
    /// or unparseable; the caller then falls back to the length rule.
    static func statedTotal(fromContentRange raw: String?) -> Int? {
        guard let raw, let slash = raw.lastIndex(of: "/") else { return nil }
        return Int(raw[raw.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// The file suffix of an unfinished dump beside the stocks.
    static let partialSuffix = ".dump.partial"

    /// An unfinished dump ON THE DISK, beside the stock files, so an app
    /// that is suspended, killed or updated mid-run continues where it was
    /// (GT-21: the slices were only ever held in memory, and a run that did
    /// not finish in one piece lost everything without a line). It keeps the
    /// total the slices named: a dump that changed upstream in between is
    /// started over instead of spliced from two versions.
    struct DumpPartial: Sendable {
        /// Through the seam (`Ablage`), like every file of the app.
        let ablage: Ablage
        let name: String
        var totalName: String { name + ".total" }
        var data: URL { ablage.url(for: name) }

        init(surface: String, directory: URL = CatalogStockStore.directory) {
            ablage = Ablage(directory: directory)
            name = surface.replacingOccurrences(of: "/", with: "_") + CatalogStockFetch.partialSuffix
        }

        func load() -> (body: Data, total: Int?) {
            let total: Int?
            if case .loaded(let held) = ablage.loadNow(Int.self, name: totalName) { total = held } else { total = nil }
            return (ablage.grownBytes(name: name) ?? Data(), total)
        }

        func append(_ slice: Data, total stated: Int?) throws {
            try ablage.append(slice, name: name)
            if let stated { try ablage.saveNow(stated, name: totalName) }
        }

        func reset() {
            ablage.removeNow(name: name)
            ablage.removeNow(name: totalName)
        }
    }

    static func gutenbergStock(partial: DumpPartial? = nil) async throws -> [CatalogStockEntry] {
        var (body, knownTotal) = partial?.load() ?? (Data(), nil)
        if !body.isEmpty {
            Logger.library.notice("STOCK gutenberg dump resumes held=\(body.count)")
        }
        var attemptsLeft = gutenbergSliceAttempts
        while true {
            var request = URLRequest(url: gutenbergDump)
            request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(body.count)-\(body.count + gutenbergSliceBytes - 1)",
                             forHTTPHeaderField: "Range")
            request.timeoutInterval = 120
            let data: Data
            let response: HTTPURLResponse?
            do {
                (data, response) = try await HTTP.data(for: request, lane: .mass)
            } catch {
                // A torn slice costs the slice, never the run: the budget
                // is per slice, so it is restored after every slice that
                // did arrive. Otherwise four tears spread over six slices
                // would throw the whole run away, which is exactly the
                // all-or-nothing this construction exists against.
                attemptsLeft -= 1
                guard attemptsLeft > 0, !error.isCancellation else { throw error }
                continue
            }
            let http = response
            if let http, http.statusCode >= 400 {
                // 416 means we asked past the end: whatever we hold IS
                // the file (a file sized an exact multiple of the slice
                // lands here), so this is an end, not a failure.
                if http.statusCode == 416, !body.isEmpty { break }
                throw APIError.http(http.statusCode, "")
            }
            // A host that ignored the Range answered with everything, so
            // what arrived IS the file and the loop is over.
            if dumpAnswerReplacesBody(status: http?.statusCode) {
                body = data
                break
            }
            let stated = statedTotal(fromContentRange: http?.value(forHTTPHeaderField: "Content-Range"))
            if dumpChangedUpstream(held: body.count, known: knownTotal, stated: stated) {
                Logger.library.notice("STOCK gutenberg dump changed upstream total=\(knownTotal ?? 0)->\(stated ?? 0); starting over")
                partial?.reset()
                body = Data()
                knownTotal = stated
                attemptsLeft = gutenbergSliceAttempts
                continue
            }
            knownTotal = stated ?? knownTotal
            body.append(data)
            do {
                try partial?.append(data, total: knownTotal)
            } catch {
                // The run goes on from memory; only its resumability is lost.
                Logger.library.error("STOCK gutenberg dump slice not kept reason=\(FailureReason.of(error), privacy: .public)")
            }
            attemptsLeft = gutenbergSliceAttempts
            let slice = DumpSlice(bytes: data.count, statedTotal: stated)
            if dumpIsComplete(held: body.count, slice: slice, sliceSize: gutenbergSliceBytes) {
                break
            }
            // An answer that brought NOTHING and claims no completeness
            // would spin forever; treat it as a tear instead.
            if data.isEmpty {
                attemptsLeft -= 1
                guard attemptsLeft > 0 else { throw APIError.decoding("catalogue dump stalled") }
            }
            try Task.checkCancellation()
        }
        guard let text = String(data: body, encoding: .utf8) else {
            // A broken file must not be resumed forever.
            partial?.reset()
            throw APIError.decoding("catalogue dump is not UTF-8")
        }
        // Whole: the unfinished file has done its work.
        partial?.reset()
        return gutenbergEntries(fromCSV: text)
    }

    /// Whether the dump changed between two slices: a total was held and
    /// the service now names another one. Pure.
    static func dumpChangedUpstream(held: Int, known: Int?, stated: Int?) -> Bool {
        guard held > 0, let known, let stated else { return false }
        return known != stated
    }

    /// What a collection COSTS on the wire, in megabytes. Measured, not
    /// estimated: a scrape call with exactly the fields the stock keeps
    /// answered 262.981 B for 1.000 entries, so 263 B per entry, and the
    /// totals are the ones the endpoint states.
    ///
    /// The number is shown to someone who is about to spend their data
    /// plan, so it may not be a guess.
    static func transferMegabytes(surface: String) -> Int? {
        let perEntry = 263.0
        let totals: [String: Int] = [
            "oldTimeRadio": 8_793,
            "librivox": 21_759,
            "archiveBooks": 75_549,
            "netlabels": 76_991,
            "shellac-all": 187_031,
        ]
        if let total = totals[surface] {
            return max(1, Int((Double(total) * perEntry / 1_000_000).rounded()))
        }
        // The Gutenberg dump is ONE file, and its size is the measurement.
        if surface == "gutenberg" { return 21 }
        return nil
    }

    // MARK: - The popularity the dump does not carry

    private struct GutendexPage: Decodable {
        struct Book: Decodable {
            let id: Int
            let download_count: Int?
        }
        let next: String?
        let results: [Book]
    }

    /// ONE page of the popularity enumeration. The caller writes the result
    /// down before asking for the next, so an interruption costs one page
    /// and not the whole run.
    ///
    /// Measured: 32 books per page, 36 pages for the whole holding, a warm
    /// page 0,35 s and a cold one up to 74 s. That is why this runs in the
    /// background and page by page, and never while a surface waits.
    static func gutenbergPopularityPage(_ page: Int) async throws -> (counts: [String: Int],
                                                                      hasMore: Bool) {
        var comp = URLComponents(string: "https://gutendex.com/books/")!
        comp.queryItems = [URLQueryItem(name: "mime_type", value: "audio/mpeg"),
                           URLQueryItem(name: "page", value: String(page))]
        var request = URLRequest(url: comp.url!)
        request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")
        // A cold page is the service COMPUTING, not the wire being slow.
        request.timeoutInterval = 120
        let (data, http) = try await HTTP.data(for: request, lane: .mass)
        if let http, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, "")
        }
        let decoded = try JSONDecoder().decode(GutendexPage.self, from: data)
        var counts: [String: Int] = [:]
        for book in decoded.results {
            if let count = book.download_count { counts["gut:\(book.id)"] = count }
        }
        return (counts, decoded.next != nil)
    }

    /// Pure, so the parse is testable against a literal of the REAL shape.
    ///
    /// Only `Type == Sound`: that is the media type of the work. gutendex
    /// filters over the FORMATS instead, which is why it also lists text
    /// works with an audio file attached. The order that the surface asks
    /// from the service carries those with it, so nothing is lost.
    static func gutenbergEntries(fromCSV text: String) -> [CatalogStockEntry] {
        var out: [CatalogStockEntry] = []
        var rows = csvRows(text)
        guard !rows.isEmpty else { return [] }
        let header = rows.removeFirst()
        func index(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let idIndex = index("Text#"), let typeIndex = index("Type"),
              let titleIndex = index("Title") else { return [] }
        let authorIndex = index("Authors")
        let subjectIndex = index("Subjects")
        let shelfIndex = index("Bookshelves")
        for row in rows where row.count > typeIndex && row[typeIndex] == "Sound" {
            guard row.count > idIndex, row.count > titleIndex else { continue }
            var subjects: [String] = []
            if let subjectIndex, row.count > subjectIndex {
                subjects += row[subjectIndex].split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if let shelfIndex, row.count > shelfIndex {
                subjects += row[shelfIndex].split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            out.append(CatalogStockEntry(
                id: "gut:\(row[idIndex])",
                title: row[titleIndex],
                creator: authorIndex.flatMap { row.count > $0 ? row[$0] : nil },
                subjects: subjects.filter { !$0.isEmpty },
                // The dump does not carry the download counts. Measured, and
                // the reason the popularity order stays with the service.
                downloads: nil,
                licenseurl: nil,
                year: nil))
        }
        return out
    }

    /// A CSV reader that honours quotes and embedded newlines. The
    /// catalogue has both: titles with commas, subjects with quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(character) }
                continue
            }
            switch character {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            case "\r": break
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
