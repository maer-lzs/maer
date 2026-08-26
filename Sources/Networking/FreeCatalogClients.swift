// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The two KEYLESS free-audiobook services. Decode failures THROW. A broken
/// answer never becomes a silently empty row.
nonisolated enum LibriVoxClient {
    /// ONE identifier for the whole app. See AppUserAgent.
    static let userAgent = AppUserAgent.value

    nonisolated static func decodeFeed(_ data: Data) throws -> [LibriVoxBook] {
        try JSONDecoder().decode(LibriVoxFeed.self, from: data).books ?? []
    }

    /// New catalog additions since `sinceDays` ago ("Neu bei LibriVox").
    /// Title search over the SAME API. The ^ prefix is the API's own
    /// stemming operator, so no second client is needed.
    static func searchBooks(title: String, limit: Int = 10) async throws -> [LibriVoxBook] {
        var comp = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "title", value: "^" + title),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeFeed(data)
    }

    /// The fields a ROW needs. `extended=1` alone answers 291 kB for 20
    /// books, of which 95 % is the chapter list; `extended=1` PLUS `fields=`
    /// answers 45 kB and still carries `genres`.
    ///
    /// `sections` is deliberately absent: a row shows no chapters. The detail
    /// path fetches the full book by id when it needs them
    /// (`FreeCatalogProvider.fetchItemDetail`). Metadata where it is needed,
    /// not on every tile.
    static let rowFields = "id,title,language,totaltimesecs,url_iarchive,"
        + "url_librivox,url_rss,authors,genres,description"

    /// `extended=1` roughly doubles the answer time (7–19 s without, 21–35 s
    /// with, same `limit`), and the server computes the whole answer before it
    /// sends the first byte. Against the shared 20 s request timeout this call
    /// therefore ran the retry ladder into a failure, so it carries its own
    /// 45 s ceiling.
    ///
    /// `extended=1` stays: it is the only way to get `url_iarchive`, and the
    /// cover of every LibriVox tile hangs off it. Neither `fields=` nor the
    /// bare form brings it back. Since the pass publishes per finished source,
    /// arriving late costs no other row anything.
    static func newBooks(sinceDays: Int, limit: Int) async throws -> [LibriVoxBook] {
        let since = Int(Date().timeIntervalSince1970) - sinceDays * 86_400
        var comp = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "fields", value: rowFields),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeFeed(data)
    }

    /// One book by id (detail resolution for popular-row playback bridges).
    static func book(id: String) async throws -> LibriVoxBook? {
        var comp = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "id", value: id),
        ]
        guard let url = comp.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeFeed(data).first
    }
}

/// Project Gutenberg audiobooks via Gutendex. Keyless JSON, the
/// audio formats ride in the answer. Rights situation is the friendliest we
/// found (measured 05.08.): public domain in the US, explicitly WITHOUT
/// purpose limitation, sharing ban or storage ban. The three clauses that
/// killed SRG. Only the TRADEMARK "Project Gutenberg" may not be used for
/// own works; naming the source is fine and we do it in the row.
nonisolated enum GutenbergClient {
    /// Also Encodable: the Gutenberg shelf stock is cached for a day, and
    /// caching the SOURCE form means a cached shelf rebuilds exactly the tiles
    /// a live one would, through the same `remember(gutenberg:)`. No second
    /// shape, no second truth.
    nonisolated struct Book: Codable, Sendable {
        let id: Int
        let title: String?
        let authors: [Author]?
        let languages: [String]?
        let formats: [String: String]?
        /// Gutendex delivers `subjects` as plain strings. Passed on
        /// so the genre axis has material here too.
        let subjects: [String]?

        nonisolated struct Author: Codable, Sendable { let name: String? }
    }

    nonisolated struct Response: Decodable, Sendable {
        let count: Int?
        let results: [Book]?
    }

    nonisolated static func decode(_ data: Data) throws -> [Book] {
        try JSONDecoder().decode(Response.self, from: data).results ?? []
    }

    /// The stock rides in the answer we fetch anyway (`count`). The same
    /// shape as `numFound` on the archive.org side. A shelf can therefore
    /// state its real size instead of its loaded excerpt.
    nonisolated static func decodeWithCount(_ data: Data) throws -> (books: [Book], total: Int?) {
        let answer = try JSONDecoder().decode(Response.self, from: data)
        return (answer.results ?? [], answer.count)
    }

    /// Audiobooks in the given languages. Gutendex pages at 32 entries; the
    /// caller decides how many pages are worth it.
    /// `topic` filters server-side over subjects AND bookshelves. Measured:
    /// philosophy 13, religion 3. Small, but that IS the stock.
    static func audiobooks(languages: [String], page: Int = 1,
                           search: String? = nil, topic: String? = nil) async throws -> [Book] {
        try await audiobooksWithTotal(languages: languages, page: page,
                                      search: search, topic: topic).books
    }

    static func audiobooksWithTotal(languages: [String], page: Int = 1,
                                    search: String? = nil, topic: String? = nil)
        async throws -> (books: [Book], total: Int?) {
        var comp = URLComponents(string: "https://gutendex.com/books/")!
        var items = [URLQueryItem(name: "mime_type", value: "audio/mpeg"),
                     URLQueryItem(name: "page", value: String(page))]
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
        }
        // gutendex's own title/author search. Same client, one param.
        if let search, !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        if let topic, !topic.isEmpty {
            items.append(URLQueryItem(name: "topic", value: topic))
        }
        comp.queryItems = items
        guard let url = comp.url else { return ([], nil) }
        var request = URLRequest(url: url)
        // gutendex computes a cold `mime_type` query in 30–40 s and answers
        // the warm one in 40 ms, so the shared 20 s ceiling could only ever be
        // met by a retry that happened to hit the warm cache. This ceiling
        // fits the source; with the per-row publish it holds nothing else up.
        request.timeoutInterval = 45
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeWithCount(data)
    }
}

/// ONE shape for "what does this source hold on this shelf". Four sources
/// behind it, and the overview row, its chevron and the full page all ask
/// through here. A source without an archive.org query answers on its own way
/// rather than staying silently empty.
///
/// The fetch stays raw and `Sendable`: turning documents into tiles needs the
/// provider and therefore the main actor, and that is the caller's job.
nonisolated enum CatalogShelfSource {
    enum Answer: Sendable {
        case archive(docs: [ArchivePopularDoc], total: Int?)
        case gutenberg(books: [GutenbergClient.Book], total: Int?)
        /// The source cannot serve shelves at all. The surface must then not
        /// promise them (`hasChips`), rather than stay silently empty.
        case unsupported
    }

    /// What a shelf query answered, in the ONE shape the day store keeps.
    /// Two kinds of stock behind it, so both lists are optional and only the
    /// one the source serves is filled.
    ///
    /// The shelves are fetched once a DAY and read from the store afterwards,
    /// for every source. A source page asks eighteen shelves, and there are
    /// six such surfaces: without a store that is the traffic of a handful of
    /// visits, and the endpoint that carries most of it hands out its stock
    /// for free.
    ///
    /// It lives in the mechanism that already has expiry, and whose founding
    /// rule is the one that matters here: **a failed lookup is never written
    /// down.** So a broken day cannot freeze the page for the rest of it.
    struct ShelfStock: Codable, Sendable {
        var total: Int?
        var books: [GutenbergClient.Book]?
        var docs: [ArchivePopularDoc]?
    }

    static let shelfStore = ResolutionCacheStore<ShelfStock>(
        key: "catalogShelfStock", dayBound: true)

    /// At most this many shelf queries are in flight at once, on every
    /// surface. MEASURED against the endpoint, eighteen shelves of one
    /// source: without a cap the pass takes 8,07 s, with a cap of six 7,72 s,
    /// and the median single query drops from 1,49 s to 1,13 s. The pass
    /// costs its SLOWEST shelf, not the sum, so the cap is free. Eighteen at
    /// once was the shape that had the endpoint refuse the connection during
    /// a measuring run.
    static let shelfConcurrency = 6

    /// The id a shelf's answer is filed under. The shelf name alone would
    /// collide: four book sources and two music surfaces ask the SAME shelf
    /// names of different stocks.
    static func stockId(surface: String, shelf: String) -> String {
        "\(surface)|\(shelf)"
    }

    /// What ONE shelf query costs COLD, measured at the endpoint: archive.org
    /// answers a single shelf in 0,99-1,49 s (median 1,13 s with the cap in
    /// place); gutendex computes a cold topic in 30-41 s and answers the warm
    /// one in 30-70 ms.
    ///
    /// The whole PASS costs MORE than one query, and it is the pass the
    /// surface waits for: eighteen archive shelves take 7,7-8,1 s, because a
    /// pass costs its slowest shelf. Whether the placeholder should therefore
    /// cover the archive surfaces too is a question about the visible form
    /// and is not decided here; this number stays what its name says.
    static func coldShelfSeconds(_ source: CatalogSource) -> Double {
        switch source {
        case .gutenberg: 35
        case .librivox, .archiveBooks, .oldTimeRadio: 1.2
        default: 0
        }
    }

    /// Is the wait long enough to be worth SAYING? The placeholder that
    /// covers the cold pass hangs on this THRESHOLD, never on a source name.
    /// A skeleton shown for one second is worse than none, and if one of the
    /// fast sources ever turns slow the same rule catches it without anyone
    /// remembering to add a special case.
    static let visibleWaitSeconds: Double = 3

    static func showsLoadingPlaceholder(_ source: CatalogSource) -> Bool {
        coldShelfSeconds(source) >= visibleWaitSeconds
    }

    /// Which shelves the stored day KNOWS this source has. The warm visit
    /// can draw exactly those and fill them in place, so nothing moves and no
    /// shelf appears that does not exist.
    static func knownShelfKeys(for source: CatalogSource) -> Set<String> {
        let day = storedDay(source: source)
        return Set(day.compactMap { key, value in
            (value?.books?.isEmpty == false || value?.docs?.isEmpty == false) ? key : nil
        })
    }

    /// The fingerprint of the rule a shelf's answer came from: the terms that
    /// were actually asked, and the stock they were asked of. When either
    /// changes, the old entry is simply not findable, without a generation
    /// counter somebody can forget to raise.
    ///
    /// Takes the STORE ID, because that is what the store hands it, and the
    /// id is what says which surface asked.
    static func shelfRule(forId id: String) -> String {
        guard let bar = id.firstIndex(of: "|") else { return "" }
        let surface = String(id[id.startIndex..<bar])
        let shelf = String(id[id.index(after: bar)...])
        if let source = CatalogSource(rawValue: surface) {
            let terms = CatalogGenreAxis.subjects(forShelf: shelf)
            // gutendex takes one topic per request and gets the three
            // richest; the archive query takes the whole list at once.
            if source == .gutenberg { return terms.prefix(3).joined(separator: "|") }
            let base = ArchiveOrgClient.archiveBaseQuery(for: source) ?? surface
            return base + "#" + terms.joined(separator: "|")
        }
        if let area = ArchiveMusicCatalog.all.first(where: { $0.key == surface }) {
            return area.query + "#"
                + CatalogGenreAxis.musicSubjects(forShelf: shelf).joined(separator: "|")
        }
        return ""
    }

    /// Whether a source can answer the shelf question at all. `hasChips` reads
    /// this instead of guessing, so a surface can never promise a shelf row
    /// that no query backs.
    static func canServeShelves(_ source: CatalogSource) -> Bool {
        switch source {
        case .librivox, .archiveBooks, .oldTimeRadio, .gutenberg: true
        default: false
        }
    }

    /// The stored day of ONE surface, keyed by shelf and read ONCE per pass.
    /// Reading it per shelf would decode the whole store eighteen times for
    /// one page. The same class as the memoized keychain read (one IPC per
    /// access in a hot path).
    static func storedDay(surface: String) -> [String: ShelfStock?] {
        var out: [String: ShelfStock?] = [:]
        for (id, value) in shelfStore.load(rule: shelfRule(forId:)) {
            let head = stockId(surface: surface, shelf: "")
            guard id.hasPrefix(head) else { continue }
            out[String(id.dropFirst(head.count))] = value
        }
        return out
    }

    static func storedDay(source: CatalogSource) -> [String: ShelfStock?] {
        storedDay(surface: source.rawValue)
    }

    /// Writes a clean shelf answer down for the day. An empty shelf is a
    /// clean ANSWER and may be remembered; only a failure may not, and that
    /// one never reaches this line because it throws before.
    static func remember(_ answer: Answer, surface: String, shelf: String, rows: Int) {
        let stock: ShelfStock
        switch answer {
        case .archive(let docs, let total):
            guard !docs.isEmpty else {
                shelfStore.store(.absent, for: stockId(surface: surface, shelf: shelf),
                                 rule: shelfRule(forId: stockId(surface: surface, shelf: shelf)))
                return
            }
            stock = ShelfStock(total: total, books: nil, docs: Array(docs.prefix(rows)))
        case .gutenberg(let books, let total):
            guard !books.isEmpty else {
                shelfStore.store(.absent, for: stockId(surface: surface, shelf: shelf),
                                 rule: shelfRule(forId: stockId(surface: surface, shelf: shelf)))
                return
            }
            stock = ShelfStock(total: total, books: Array(books.prefix(rows)), docs: nil)
        case .unsupported:
            return
        }
        let id = stockId(surface: surface, shelf: shelf)
        shelfStore.store(.found(stock), for: id, rule: shelfRule(forId: id))
    }

    /// The stored day as an ANSWER, so a warm visit and a cold one hand the
    /// same shape to the surface.
    static func answer(from stock: ShelfStock?, source: CatalogSource) -> Answer {
        source == .gutenberg
            ? .gutenberg(books: stock?.books ?? [], total: stock?.total)
            : .archive(docs: stock?.docs ?? [], total: stock?.total)
    }

    /// The OVERVIEW's shelf preview. Same query as the full page, plus the
    /// day store. A throw propagates and stores NOTHING, so a bad minute
    /// cannot freeze the page for the rest of the day.
    static func preview(source: CatalogSource, shelf: String, languages: [String],
                        rows: Int, storedDay: [String: ShelfStock?] = [:]) async throws -> Answer {
        if let stored = storedDay[shelf] { return answer(from: stored, source: source) }
        let answer = try await page(source: source, shelf: shelf,
                                    languages: languages, rows: rows)
        remember(answer, surface: source.rawValue, shelf: shelf, rows: rows)
        return answer
    }

    /// A DECADE shelf through the day store. Its query is fully determined by
    /// the base query and the decade in the id, so the fingerprint needs no
    /// term list.
    static func decadePreview(source: CatalogSource, decade: String, rows: Int,
                              storedDay: [String: ShelfStock?] = [:]) async throws -> Answer {
        if let stored = storedDay[decade] {
            return .archive(docs: stored?.docs ?? [], total: stored?.total)
        }
        let answer = try await decadePage(source: source, decade: decade, rows: rows)
        remember(answer, surface: source.rawValue, shelf: decade, rows: rows)
        return answer
    }

    /// The POPULAR row of a music area, through the same day store. The
    /// shellac surface asks it once per area, so a visit is ten queries in
    /// series; stored, it is ten per day.
    /// `slot` separates two rows that ask the SAME area on different pages.
    /// Without it the tab row and the row on the area page would overwrite
    /// each other's day, and one of them would show the other's excerpt.
    static func areaPopular(area: ArchiveMusicArea, rows: Int, page: Int,
                            slot: String = popularShelf,
                            storedDay: [String: ShelfStock?] = [:]) async throws -> [ArchivePopularDoc] {
        if let stored = storedDay[slot] { return stored?.docs ?? [] }
        let docs = try await ArchiveOrgClient.popularMusic(area: area, rows: rows, page: page)
        remember(.archive(docs: docs, total: nil), surface: area.key, shelf: slot, rows: rows)
        return docs
    }

    /// The shelf name under which an area's popular row is filed. It is not a
    /// genre, so it carries no terms; its fingerprint is the area query
    /// alone, and that is exactly what decides its content.
    static let popularShelf = "popular"

    /// The music surfaces' shelf query. It lived in the view and therefore
    /// had neither the day store nor the cap; here it shares both, and the
    /// term list stays where every other shelf query takes it from.
    static func musicPage(area: ArchiveMusicArea, shelf: String, rows: Int,
                          storedDay: [String: ShelfStock?] = [:]) async throws -> Answer {
        if let stored = storedDay[shelf] {
            return .archive(docs: stored?.docs ?? [], total: stored?.total)
        }
        let terms = CatalogGenreAxis.musicSubjects(forShelf: shelf)
        guard !terms.isEmpty else { return .unsupported }
        // No cap on the term list: `subject:` matches exactly, so a longer OR
        // is simply more stock (measured: a factor of nine for 0,05 s).
        let clause = terms.map { "subject:\"\($0)\"" }.joined(separator: " OR ")
        let hit = try await ArchiveOrgClient.popularWithTotal(
            query: "\(area.query) AND (\(clause))", rows: rows)
        let answer = Answer.archive(docs: hit.docs, total: hit.total)
        remember(answer, surface: area.key, shelf: shelf, rows: rows)
        return answer
    }

    /// A DECADE shelf. It asks the `year` field as a range instead of
    /// or-joining eleven subject spellings. More exact, shorter, and it also
    /// catches the entries that carry the year only in the year field.
    static func decadePage(source: CatalogSource, decade: String,
                           rows: Int, page: Int = 1) async throws -> Answer {
        guard let base = ArchiveOrgClient.archiveBaseQuery(for: source),
              let start = Int(decade.dropLast()) else { return .unsupported }
        let hit = try await ArchiveOrgClient.popularWithTotal(
            query: "\(base) AND year:[\(start) TO \(start + 9)]", rows: rows, page: page)
        return .archive(docs: hit.docs, total: hit.total)
    }

    /// Which page a shelf's PREVIEW shows. The preview only. Whoever opens
    /// the full page starts from the front.
    static func shelfPage(shelf: String, rows: Int, on date: Date = Date()) -> Int {
        CatalogRotation.page(total: 600, rowSize: rows, on: date,
                             salt: CatalogRotation.salt(forShelf: shelf))
    }

    static func page(source: CatalogSource, shelf: String, languages: [String],
                     rows: Int, page: Int = 1) async throws -> Answer {
        // A decade shelf runs through the same ONE door as a genre shelf,
        // otherwise its chevron would lead to an empty page.
        if CatalogGenreAxis.decadeShelves.contains(where: { $0.key == shelf }) {
            return try await decadePage(source: source, decade: shelf, rows: rows, page: page)
        }
        let terms = CatalogGenreAxis.subjects(forShelf: shelf)
        guard !terms.isEmpty else { return .unsupported }
        switch source {
        case .librivox, .archiveBooks, .oldTimeRadio:
            guard let base = ArchiveOrgClient.archiveBaseQuery(for: source) else { return .unsupported }
            // No cap on the term list: `subject:` matches exactly, so a
            // longer OR is simply more stock here. The cap belongs to
            // Jamendo's fuzzy `fuzzytags`, not here. Measured, it costs a
            // factor of nine in stock at the same response time.
            let clause = terms.map { "subject:\"\($0)\"" }.joined(separator: " OR ")
            // The preview reaches into a DIFFERENT place of the stock per
            // shelf. Otherwise two shelves that share a title begin with the
            // same tile.
            let hit = try await ArchiveOrgClient.popularWithTotal(
                query: "\(base) AND (\(clause))", rows: rows,
                page: page == 1 ? shelfPage(shelf: shelf, rows: rows) : page)
            return .archive(docs: hit.docs, total: hit.total)
        case .gutenberg:
            // gutendex takes ONE topic per request, so this asks the three
            // richest terms instead of the alphabetically first ones. They
            // run CONCURRENTLY, because sequentially each term cost a full
            // 30 s cold. Three at once therefore cost as much as one, and the
            // cap no longer has to be weighed against reach.
            let topics = Array(terms.prefix(3))
            let hits = await withTaskGroup(of: (books: [GutenbergClient.Book], total: Int?)?.self) { group in
                for topic in topics {
                    group.addTask {
                        try? await GutenbergClient.audiobooksWithTotal(
                            languages: languages, page: page, topic: topic)
                    }
                }
                var out: [(books: [GutenbergClient.Book], total: Int?)] = []
                for await hit in group { if let hit { out.append(hit) } }
                return out
            }
            guard !hits.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
            var seen = Set<Int>()
            var books: [GutenbergClient.Book] = []
            for hit in hits where !hit.books.isEmpty {
                for book in hit.books where seen.insert(book.id).inserted { books.append(book) }
            }
            // When a shelf carries a number, it is the number of the STOCK.
            // Over several topics a sum would be invented, because the sets
            // overlap. The number therefore exists only where exactly ONE
            // topic carries the shelf; otherwise the chevron takes its
            // existence form.
            let total = topics.count == 1 ? hits.first?.total : nil
            return .gutenberg(books: books, total: total)
        default:
            return .unsupported
        }
    }
}

nonisolated enum ArchiveOrgClient {
    nonisolated struct SearchResponse: Decodable {
        struct Body: Decodable {
            let docs: [ArchivePopularDoc]?
            /// The STOCK behind a query. How much there is, not how much
            /// happened to be loaded. The server states it; this only carries
            /// it through to the shelf heading.
            let numFound: Int?
        }
        let response: Body?
    }
    nonisolated struct MetadataResponse: Decodable {
        struct Meta: Decodable {
            // Same list-capable fields on the metadata endpoint.
            let title: ArchiveStringList?
            let creator: ArchiveStringList?
            /// The item description for the series and detail pages.
            let description: ArchiveStringList?
            /// The collections. The item's FORM is read from them, and on
            /// this endpoint it arrives even for an item that was never in a
            /// row (a deep link, a playlist entry, a cold start).
            let collection: ArchiveStringList?
        }
        let files: [ArchiveFile]?
        let metadata: Meta?
    }

    nonisolated static func decodePopular(_ data: Data) throws -> [ArchivePopularDoc] {
        try JSONDecoder().decode(SearchResponse.self, from: data).response?.docs ?? []
    }

    /// How many items the query has IN TOTAL. The number a shelf heading
    /// names. No second request: the stock rides along with the page that is
    /// being fetched anyway.
    nonisolated static func decodeTotal(_ data: Data) throws -> Int? {
        try JSONDecoder().decode(SearchResponse.self, from: data).response?.numFound
    }

    /// ONE curated classical query. The George-Blood 78rpm digitization
    /// project with the classical subject (4k+ clean single titles with
    /// composer metadata; probed against 78rpm/musopen/europeanlibraries.
    /// One good collection beats three noisy ones).
    /// The query itself now lives with the area data (`ArchiveMusicCatalog`).
    /// One place for every archive.org music area.
    static var classicalQuery: String { ArchiveMusicCatalog.classical.query }

    /// Most-downloaded LibriVox items (the keyless popularity source).
    /// Language filters SERVER-side (ISO-639-3 clause); an empty
    /// language result falls back to unfiltered (rule unchanged).
    static func popularLibriVox(rows: Int, languageCodes: [String] = [], page: Int = 1) async throws -> [ArchivePopularDoc] {
        if let clause = FreeCatalog.archiveLanguageClause(codes: languageCodes) {
            let filtered = try await popular(
                query: "collection:librivoxaudio AND \(clause)", rows: rows, page: page)
            if !filtered.isEmpty { return filtered }
            // Fallback only on the FIRST page. Deeper pages legitimately end.
            guard page == 1 else { return [] }
        }
        return try await popular(query: "collection:librivoxaudio AND mediatype:(audio)", rows: rows, page: page)
    }

    /// Popularity PER LANGUAGE, then interleaved. One combined
    /// query ranks by absolute download counts, where English buries every
    /// minority language. The measured effect behind "the row only ever
    /// shows English". Queries run concurrently; a failing language drops
    /// out instead of taking the row down with it.
    static func popularLibriVoxByLanguage(rowsPerLanguage: Int, languageCodes: [String],
                                          limit: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        let codes = languageCodes.isEmpty ? [""] : languageCodes
        // Per-language errors are collected: if EVERY language fails, that
        // is a row FAILURE and throws instead of collapsing to an empty row
        // with neither content nor error line. A partial failure stays
        // best-effort. The surviving languages fill the row.
        let results: [(Int, Result<[ArchivePopularDoc], Error>)] =
            await withTaskGroup(of: (Int, Result<[ArchivePopularDoc], Error>).self) { group in
                for (index, code) in codes.enumerated() {
                    group.addTask {
                        do {
                            return (index, .success(try await popularLibriVox(
                                rows: rowsPerLanguage,
                                languageCodes: code.isEmpty ? [] : [code], page: page)))
                        } catch { return (index, .failure(error)) }
                    }
                }
                var all: [(Int, Result<[ArchivePopularDoc], Error>)] = []
                for await entry in group { all.append(entry) }
                return all
            }
        let byIndex = Dictionary(uniqueKeysWithValues: results)
        let failures = results.compactMap { if case .failure(let e) = $0.1 { e } else { nil } }
        if failures.count == codes.count, let first = failures.first { throw first }
        let lists = codes.indices.map { (try? byIndex[$0]?.get()) ?? [] }
        return FreeCatalog.interleaveByLanguage(lists, limit: limit) { $0.identifier ?? "" }
    }

    /// Old Time Radio. The curated radio-play collection, but ONLY
    /// items with a stated licence. Measured 05.08.: 8.854 items total, 2.316
    /// with `licenseurl` (26 %). We do not suggest anything whose rights
    /// situation is unknown, and "no statement" is not "free".
    /// The DISPLAY path carries no licence filter: what lies there publicly
    /// is shown and streamed, and an entry without a statement visibly
    /// carries the note about its unclear rights situation. Never nothing at
    /// all, never a claim. Filtering happens only where a COPY comes into
    /// being. See `mayDownload`.
    static let oldTimeRadioQuery = "collection:oldtimeradio"

    static func popularOldTimeRadio(rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popular(query: oldTimeRadioQuery, rows: rows, page: page)
    }

    /// Audiobooks in `audio_bookspoetry` OUTSIDE LibriVox.
    /// The triple filter is not a quality guard but the CORRECT QUERY. The
    /// same class as LibriVox new-arrivals and the genre-less charts:
    /// `mediatype:(audio)` (without it the collection returns TEXT items.
    /// Plato's "Republic" as EPUB, measured), a stated licence (we suggest
    /// nothing whose rights are unknown), and the language.
    ///
    /// Entdopplung (the measured finding): user-made compilations of
    /// LibriVox recordings slip through `NOT collection:librivoxaudio`. The
    /// identifier/creator carries "librivox", so it is excluded here rather
    /// than showing the same content twice.
    /// The language fallback is a SESSION state, not a page property: a
    /// first-page-only guard ends the 4,257-item trove after ~20 titles for
    /// German users, because page 2 queries WITH the filter again, gets
    /// nothing and reads as reachedEnd. The pager passes the returned
    /// `unfiltered` back in, so deeper pages keep browsing the unfiltered
    /// corpus once the fallback happened (one truth, held by the caller).
    /// `fetch` is injectable so the decision chain is unit-testable.
    /// The base query of a source lives in exactly ONE place.
    /// The shelf pages used to REBUILD it and thereby lost three decided
    /// points at once. The LibriVox de-duplication (1.098 of 1.602 hits were
    /// duplicates), the licence clause (178 titles without any rights
    /// statement) and, through `isCuratedArchiveDoc`, the MacLean denylist.
    /// A shelf appends its subject clause to THIS string; it never writes its
    /// own.
    /// `.librivox` is in here too, with the SAME query the popular row falls
    /// back to (`popularLibriVox`), so shelf, chevron and full page count one
    /// stock. No licence clause: LibriVox is public domain by source, and the
    /// popular row carries none either. One here would shrink the shelves.
    static func archiveBaseQuery(for source: CatalogSource) -> String? {
        switch source {
        case .librivox:
            "collection:librivoxaudio AND mediatype:(audio)"
        case .archiveBooks:
            "collection:audio_bookspoetry AND NOT collection:librivoxaudio"
                + " AND mediatype:(audio)"
        case .oldTimeRadio:
            oldTimeRadioQuery + " AND mediatype:(audio)"
        default:
            nil
        }
    }

    static func audiobooksOutsideLibriVox(
        rows: Int, languageCodes: [String], page: Int = 1, unfiltered: Bool = false,
        fetch: (String, Int, Int) async throws -> [ArchivePopularDoc] = { try await popular(query: $0, rows: $1, page: $2) }
    ) async throws -> (docs: [ArchivePopularDoc], unfiltered: Bool) {
        let base = archiveBaseQuery(for: .archiveBooks)!
        // Without dropping the NOT clause this row is empty for German
        // users: every German audiobook in the collection is a LibriVox title
        // (measured: (deu OR ger) with the clause ⇒ 0, without ⇒ 844).
        if !unfiltered, let language = FreeCatalog.archiveLanguageClause(codes: languageCodes) {
            let filtered = try await fetch(base + " AND \(language)", rows, page)
            if !filtered.isEmpty { return (filtered.filter { FreeCatalog.isCuratedArchiveDoc($0) }, false) }
            // Filtered mode with stock on deeper pages legitimately ends.
            guard page == 1 else { return ([], false) }
        }
        let docs = try await fetch(base, rows, page)
        return (docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }, true)
    }

    /// Popular free classical recordings. Same client, one component.
    /// Netlabels/78s/classical all ride this ONE query path. The area
    /// carries its own `q` (ArchiveMusicCatalog), the client stays generic.
    static func popularMusic(area: ArchiveMusicArea, rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popularArchiveMusic(query: area.query, rows: rows, page: page)
    }

    static func popularClassical(rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popularArchiveMusic(query: ArchiveMusicCatalog.classical.query, rows: rows, page: page)
    }

    static func popularArchiveMusic(query: String, rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popular(query: query, rows: rows, page: page)
    }

    /// Shared advancedsearch (downloads sort). One mechanism for both rows.
    /// `sort` defaults to the popularity ranking; the shuffle gesture passes
    /// "random" (measured: the value works, but archive.org caches it
    /// for a few minutes. The caller varies the PAGE as well).
    /// One page of a query PLUS the stock behind it. `popular` keeps its name
    /// and simply drops the number. One request, one truth, no second query
    /// path that could drift.
    static func popular(query: String, rows: Int, page: Int = 1,
                        sort: String = "downloads desc") async throws -> [ArchivePopularDoc] {
        try await popularWithTotal(query: query, rows: rows, page: page, sort: sort).docs
    }

    static func popularWithTotal(query: String, rows: Int, page: Int = 1,
                                 sort: String = "downloads desc") async throws
        -> (docs: [ArchivePopularDoc], total: Int?) {
        var comp = URLComponents(string: "https://archive.org/advancedsearch.php")!
        comp.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "downloads"),
            // The licence rides along so the row can SHOW it.
            URLQueryItem(name: "fl[]", value: "licenseurl"),
            // The card's time line (present for most items).
            URLQueryItem(name: "fl[]", value: "runtime"),
            // The recording year is the ONLY hint the user gets for
            // items whose rights status the source does not state (georgeblood
            // carries no licenceurl at all). Present for about a third of them.
            // Measured, not assumed.
            URLQueryItem(name: "fl[]", value: "year"),
            // Subjects ride along so the genre axis has material for
            // the archive.org rows too (they were never requested before).
            URLQueryItem(name: "fl[]", value: "subject"),
            // The collections decide the item's form (work in parts or album
            // of tracks). Requested here, in the one place every archive.org
            // row, shelf and search goes through. So an item carries its form
            // no matter which surface found it.
            URLQueryItem(name: "fl[]", value: "collection"),
            URLQueryItem(name: "sort[]", value: sort),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = comp.url else { return ([], nil) }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        // Shared artifact filter for BOTH rows (books + classical).
        // Dropped docs are logged upstream via the count difference.
        do {
            let docs = try decodePopular(data).filter {
                !FreeCatalog.isArtifactDoc(identifier: $0.identifier, title: $0.title?.joined)
            }
            return (docs, try? decodeTotal(data))
        } catch {
            // A decode failure stays TELLABLE from transport: archive.org
            // can answer 200 with an HTML challenge. Status and the first
            // bytes ride along (no URLs, so nothing to mask).
            let status = response?.statusCode
            let prefix = String(decoding: data.prefix(80), as: UTF8.self)
            throw FreeCatalog.CatalogDecodeError(status: status, answerPrefix: prefix)
        }
    }

    /// The metadata WITHOUT the file list, over the sub-path archive.org
    /// serves for it: 8,3 kB instead of 1,36 MB (measured. 99 % of the full
    /// answer is the file list, for one OTR bundle 3.966 entries with
    /// checksums plus 66 user reviews).
    ///
    /// Only ONE caller needs this shape: the detail sheet, which wants the
    /// description. Everything else needs the files, and for those the full
    /// answer IS the point. This is not a cheaper version of that call, it
    /// is a different question.
    static func metadataOnly(identifier: String) async throws -> MetadataResponse.Meta? {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)/metadata") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        // MEASURED, not assumed: the sub-path wraps its answer in `result`
        // (8.282 B against 1.359.765 B for the same item. Factor 164).
        // Decoding it as the bare block would have answered nothing at all,
        // silently, which is exactly how the cover field was almost lost.
        struct SubPath: Decodable { let result: MetadataResponse.Meta? }
        return try JSONDecoder().decode(SubPath.self, from: data).result
    }

    /// Item metadata (files with lengths → direct stream URLs).
    static func metadata(identifier: String) async throws -> MetadataResponse {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        // 🟡 This call is the place that LEARNS whether an item still
        // exists. Every detail open and every playback start goes through
        // it. The three-way ladder decides what may be remembered; a
        // transport failure throws and remembers nothing (unknown).
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        DeadCatalogItems.note(
            DeadCatalogItems.liveness(httpStatus: response?.statusCode, body: data),
            for: identifier)
        return try JSONDecoder().decode(MetadataResponse.self, from: data)
    }

    /// The cheap liveness probe for the few PICKS a curated row shows. One
    /// metadata GET per pick. Never throws: a service failure answers
    /// `unknown` and leaves the stock untouched.
    static func liveness(identifier: String) async -> DeadCatalogItems.Liveness {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)") else {
            return .unknown
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.maer.data(for: request) else {
            return .unknown
        }
        return DeadCatalogItems.liveness(
            httpStatus: (response as? HTTPURLResponse)?.statusCode, body: data)
    }
}

/// Jamendo. Client_id via BUILD INJECTION (never in the repo) or the user's
/// own key from the network-services page. No key → nil → the row silently
/// stays away (documented capability, not an error).
nonisolated enum JamendoClient {
    nonisolated struct TracksResponse: Decodable {
        let results: [JamendoTrack]?
    }

    /// Key resolution: user key beats the build-injected one, over the shared
    /// `AppStorageKeys.resolvedAppKey` path (same as PodcastIndex).
    @MainActor
    static func clientId() -> String? {
        let resolved = AppStorageKeys.resolvedAppKey(
            user: UserDefaults.standard.string(forKey: AppStorageKeys.jamendoClientId) ?? "",
            injected: Bundle.main.object(forInfoDictionaryKey: "JamendoClientId") as? String)
        return resolved.isEmpty ? nil : resolved
    }

    nonisolated static func decodeTracks(_ data: Data) throws -> [JamendoTrack] {
        try JSONDecoder().decode(TracksResponse.self, from: data).results ?? []
    }

    /// Weekly popularity chart (CC music; ToS: attribution + backlink per
    /// track. The detail sheet carries both).
    /// `tags` loads a genre shelf SERVER-side (fuzzytags, +-joined = OR.
    /// Better than filtering a local 200 pool); `offset` pages the shelf
    /// grid.
    /// Mood, tempo and instrumental are FILTERS on a shelf's full page, not
    /// row families of their own.
    ///
    /// Jamendo filters all three SERVER-side, probed at the endpoint
    /// (`vocalinstrumental=instrumental`, `speed=high|low`, mood over
    /// `fuzzytags`). The page throws nothing away afterwards, and the number
    /// at the chevron stays the number of what one gets.
    static func popularTracks(limit: Int, tags: [String] = [], offset: Int = 0,
                              filter: JamendoFilter = .none) async throws -> [JamendoTrack] {
        guard let id = await clientId() else { return [] }
        var comp = URLComponents(string: "https://api.jamendo.com/v3.0/tracks/")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "popularity_week"),
            URLQueryItem(name: "audioformat", value: "mp32"),
        ]
        let alleTags = tags + filter.extraTags
        if !alleTags.isEmpty {
            comp.queryItems?.append(URLQueryItem(name: "fuzzytags", value: alleTags.joined(separator: "+")))
        }
        comp.queryItems?.append(contentsOf: filter.queryItems)
        if offset > 0 {
            comp.queryItems?.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeTracks(data)
    }
}
