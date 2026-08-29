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
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, "")
        }
        let decoded = try JSONDecoder().decode(ScrapeResponse.self, from: data)
        return Slice(entries: decoded.items.compactMap(entry(from:)),
                     cursor: decoded.cursor,
                     total: decoded.total ?? decoded.items.count)
    }

    private static func entry(from item: ScrapeResponse.Item) -> CatalogStockEntry? {
        guard let id = item.identifier, let title = item.title?.first else { return nil }
        return CatalogStockEntry(id: id,
                                 title: title,
                                 creator: item.creator?.first,
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
    static func gutenbergStock() async throws -> [CatalogStockEntry] {
        var request = URLRequest(url: gutenbergDump)
        request.setValue(AppUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, "")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decoding("catalogue dump is not UTF-8")
        }
        return gutenbergEntries(fromCSV: text)
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
