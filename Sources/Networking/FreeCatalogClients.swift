// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 0714d26 E1: the two KEYLESS free-audiobook services. Decode failures
/// THROW (badPayload-Lehre — never a silent empty row on a broken answer).
nonisolated enum LibriVoxClient {
    /// EINE Kennung fuer die ganze App (Befund 09.08.) — siehe AppUserAgent.
    static let userAgent = AppUserAgent.value

    nonisolated static func decodeFeed(_ data: Data) throws -> [LibriVoxBook] {
        try JSONDecoder().decode(LibriVoxFeed.self, from: data).books ?? []
    }

    /// New catalog additions since `sinceDays` ago ("Neu bei LibriVox").
    /// Q1: title search over the SAME API (the ^ prefix is the API's own
    /// stemming operator — no new client).
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

    /// R45/R48: the fields a ROW needs. Measured at the live endpoint —
    /// `extended=1` alone answers 291 kB for 20 books, of which **95 % is the
    /// chapter list**; `extended=1` PLUS `fields=` answers **45 kB** and
    /// still carries `genres`, which the full response does too but nobody
    /// asked for. Factor 6,4, and MORE content than before.
    ///
    /// `sections` is deliberately absent: a row shows no chapters. The detail
    /// path fetches the full book by id when it needs them
    /// (`FreeCatalogProvider.fetchItemDetail`) — metadata where it is needed,
    /// not on every tile.
    static let rowFields = "id,title,language,totaltimesecs,url_iarchive,"
        + "url_librivox,url_rss,authors,genres,description"

    /// R45 Runde 2 — measured at the endpoint, interleaved over four rounds:
    /// `extended=1` roughly DOUBLES the answer time (7–19 s without, 21–35 s
    /// with, same `limit`), and the server computes the whole answer before it
    /// sends the first byte (time-to-first-byte ≈ total, 22–25 s). The shared
    /// request timeout is 20 s, so this call regularly breached it and then
    /// ran the retry ladder (20 + 20 + 20 ≈ 62 s) into a FAILURE — that was
    /// the "loads forever" on the catalogue page, not the row size.
    ///
    /// The answer is therefore a LIMIT, not a parameter: this call gets its own
    /// 45 s like gutendex did. Dropping `extended=1` would halve the time, but
    /// it is measured to be the only way to get `url_iarchive` — the cover of
    /// every LibriVox tile hangs off it (`fields=` does not bring it back, and
    /// neither does the bare form). A row that arrives late is a row; a row
    /// without covers is a defect. Since the pass now publishes per finished
    /// source, arriving late costs no other row anything.
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

/// 0ce5df3: Project Gutenberg audiobooks via Gutendex — keyless JSON, the
/// audio formats ride in the answer. Rights situation is the friendliest we
/// found (measured 05.08.): public domain in the US, explicitly WITHOUT
/// purpose limitation, sharing ban or storage ban — the three clauses that
/// killed SRG. Only the TRADEMARK "Project Gutenberg" may not be used for
/// own works; naming the source is fine and we do it in the row.
nonisolated enum GutenbergClient {
    /// R53: also Encodable — the Gutenberg shelf stock is cached for a day
    /// (the owner's decision), and caching the SOURCE form means a cached shelf
    /// rebuilds exactly the tiles a live one would, through the same
    /// `remember(gutenberg:)`. No second shape, no second truth.
    nonisolated struct Book: Codable, Sendable {
        let id: Int
        let title: String?
        let authors: [Author]?
        let languages: [String]?
        let formats: [String: String]?
        /// 48e786d: gutendex delivers `subjects` as plain strings — passed on
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

    /// R53: the stock rides in the answer we fetch anyway (`count`) and was
    /// thrown away at decode time — the same shape as `numFound` on the
    /// archive.org side. A shelf can therefore state its real size instead of
    /// its loaded excerpt.
    nonisolated static func decodeWithCount(_ data: Data) throws -> (books: [Book], total: Int?) {
        let answer = try JSONDecoder().decode(Response.self, from: data)
        return (answer.results ?? [], answer.count)
    }

    /// Audiobooks in the given languages. Gutendex pages at 32 entries; the
    /// caller decides how many pages are worth it.
    /// `topic` (R1) filters server-side over subjects AND bookshelves —
    /// measured 09.08.: philosophy 13, religion 3. Small, but that IS the
    /// stock; the shelf shows honestly what exists.
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
        // Q1: gutendex's own title/author search — same client, one param.
        if let search, !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        if let topic, !topic.isEmpty {
            items.append(URLQueryItem(name: "topic", value: topic))
        }
        comp.queryItems = items
        guard let url = comp.url else { return ([], nil) }
        var request = URLRequest(url: url)
        // R45 invariant 3: a limit a source can NEVER meet is a wrong limit.
        // Measured: gutendex computes a cold `mime_type` query in 30–40 s and
        // answers the warm one in 40 ms — against the shared 20 s ceiling it
        // could only ever win on the retry that happened to hit its own warm
        // cache (20 + 20 + 0,05 s). The ceiling now fits the source; with the
        // per-row publish this source no longer holds anything else up.
        request.timeoutInterval = 45
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeWithCount(data)
    }
}

/// R53: ONE shape for "what does this source hold on this shelf" — four
/// sources behind it, and the overview row, its chevron and the full page all
/// ask through here. Before this, the question went through
/// `archiveBaseQuery` alone, so the two sources without an archive.org query
/// (LibriVox, Gutenberg) silently answered nothing and lost every shelf row.
///
/// The fetch stays raw and `Sendable`: turning documents into tiles needs the
/// provider and therefore the main actor, and that is the caller's job.
nonisolated enum CatalogShelfSource {
    enum Answer: Sendable {
        case archive(docs: [ArchivePopularDoc], total: Int?)
        case gutenberg(books: [GutenbergClient.Book], total: Int?)
        /// The source cannot serve shelves at all — the surface must then not
        /// promise them (`hasChips`), rather than stay silently empty.
        case unsupported
    }

    /// the owner's decision: the GUTENBERG shelves are fetched once a day and
    /// read from store afterwards. Only Gutenberg — archive.org answers a
    /// shelf in 0,63–0,80 s, where a store would be work without a win and a
    /// second truth beside it. gutendex costs 30–41 s per COLD topic and
    /// 30–70 ms warm (its own server cache); capping concurrency would still
    /// mean eighteen requests per VISIT, the store means eighteen per DAY.
    ///
    /// It lives in the mechanism that already has expiry, and whose founding
    /// rule is the one that matters here: **a failed lookup is never written
    /// down.** So a broken day cannot freeze the page for the rest of it.
    struct GutenbergShelf: Codable, Sendable {
        var total: Int?
        var books: [GutenbergClient.Book]
    }

    static let gutenbergShelfStore = ResolutionCacheStore<GutenbergShelf>(
        key: "catalogGutenbergShelfStock", positiveTTL: 24 * 3600, negativeTTL: 24 * 3600)

    /// What ONE shelf query costs COLD, measured at the endpoint:
    /// archive.org answers in 0,63-0,80 s (all shelves concurrently, so the
    /// whole cold pass is about a second); gutendex computes a cold topic in
    /// 30-41 s and answers the warm one in 30-70 ms.
    static func coldShelfSeconds(_ source: CatalogSource) -> Double {
        switch source {
        case .gutenberg: 35
        case .librivox, .archiveBooks, .oldTimeRadio: 0.8
        default: 0
        }
    }

    /// Is the wait long enough to be worth SAYING? The placeholder that
    /// covers the cold pass hangs on this THRESHOLD, never on a source name —
    /// a skeleton shown for one second is worse than none, and if one of the
    /// fast sources ever turns slow the same rule catches it without anyone
    /// remembering to add a special case.
    static let visibleWaitSeconds: Double = 3

    static func showsLoadingPlaceholder(_ source: CatalogSource) -> Bool {
        coldShelfSeconds(source) >= visibleWaitSeconds
    }

    /// Which shelves the stored day KNOWS this source has — the warm visit
    /// can draw exactly those and fill them in place, so nothing moves and no
    /// shelf appears that does not exist.
    static func knownShelfKeys(for source: CatalogSource) -> Set<String> {
        guard source == .gutenberg else { return [] }
        return Set(gutenbergShelfStore.load().compactMap { key, value in
            (value?.books.isEmpty == false) ? key : nil
        })
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

    /// The OVERVIEW's shelf preview. Same query as the full page, plus the
    /// day store for Gutenberg. A throw propagates and stores NOTHING — so a
    /// bad minute cannot freeze the page for the rest of the day.
    /// The stored day, read ONCE per pass. Reading it per shelf would decode
    /// the whole store eighteen times for one page — the same class as the
    /// memoized keychain read (one IPC per access in a hot path).
    static func storedDay() -> [String: GutenbergShelf?] { gutenbergShelfStore.load() }

    static func preview(source: CatalogSource, shelf: String, languages: [String],
                        rows: Int, storedDay: [String: GutenbergShelf?] = [:]) async throws -> Answer {
        if source == .gutenberg, let stored = storedDay[shelf] {
            return .gutenberg(books: stored?.books ?? [], total: stored?.total)
        }
        let answer = try await page(source: source, shelf: shelf,
                                    languages: languages, rows: rows)
        if source == .gutenberg, case .gutenberg(let books, let total) = answer {
            // An empty shelf is a clean ANSWER and may be remembered; only a
            // failure may not — and that one never reaches this line.
            gutenbergShelfStore.store(
                books.isEmpty ? .absent
                              : .found(GutenbergShelf(total: total, books: Array(books.prefix(rows)))),
                for: shelf)
        }
        return answer
    }

    /// R47: ein JAHRZEHNT-Fach. Es fragt das `year`-Feld als Spanne statt
    /// elf Schlagwort-Varianten zu veroderten — exakter, kuerzer, und es
    /// trifft auch die Eintraege, die das Jahr nur im Jahresfeld fuehren.
    static func decadePage(source: CatalogSource, decade: String,
                           rows: Int, page: Int = 1) async throws -> Answer {
        guard let base = ArchiveOrgClient.archiveBaseQuery(for: source),
              let start = Int(decade.dropLast()) else { return .unsupported }
        let hit = try await ArchiveOrgClient.popularWithTotal(
            query: "\(base) AND year:[\(start) TO \(start + 9)]", rows: rows, page: page)
        return .archive(docs: hit.docs, total: hit.total)
    }

    static func page(source: CatalogSource, shelf: String, languages: [String],
                     rows: Int, page: Int = 1) async throws -> Answer {
        // R47: ein Jahrzehnt-Fach laeuft ueber dieselbe EINE Tuer wie ein
        // Gattungs-Fach — sonst fuehrte sein Chevron auf eine leere Seite.
        if CatalogGenreAxis.decadeShelves.contains(where: { $0.key == shelf }) {
            return try await decadePage(source: source, decade: shelf, rows: rows, page: page)
        }
        let terms = CatalogGenreAxis.subjects(forShelf: shelf)
        guard !terms.isEmpty else { return .unsupported }
        switch source {
        case .librivox, .archiveBooks, .oldTimeRadio:
            guard let base = ArchiveOrgClient.archiveBaseQuery(for: source) else { return .unsupported }
            let clause = terms.prefix(6).map { "subject:\"\($0)\"" }.joined(separator: " OR ")
            let hit = try await ArchiveOrgClient.popularWithTotal(
                query: "\(base) AND (\(clause))", rows: rows, page: page)
            return .archive(docs: hit.docs, total: hit.total)
        case .gutenberg:
            // gutendex takes ONE topic per request; a shelf folds a few, so
            // the same two the full page uses are asked and merged.
            var books: [GutenbergClient.Book] = []
            var total = 0
            var sawTotal = false
            for topic in terms.prefix(2) {
                let hit = try await GutenbergClient.audiobooksWithTotal(
                    languages: languages, page: page, topic: topic)
                books += hit.books
                if let count = hit.total { total += count; sawTotal = true }
            }
            return .gutenberg(books: books, total: sawTotal ? total : nil)
        default:
            return .unsupported
        }
    }
}

nonisolated enum ArchiveOrgClient {
    nonisolated struct SearchResponse: Decodable {
        struct Body: Decodable {
            let docs: [ArchivePopularDoc]?
            /// R46: the STOCK behind a query. A shelf that shows 1 of 102 was
            /// not lying about the tiles — it was answering a different
            /// question ("what did I happen to load") than the one the
            /// heading asks ("how much is there"). The server states it; we
            /// only have to carry it.
            let numFound: Int?
        }
        let response: Body?
    }
    nonisolated struct MetadataResponse: Decodable {
        struct Meta: Decodable {
            // 3ac9183: same list-capable fields on the metadata endpoint.
            let title: ArchiveStringList?
            let creator: ArchiveStringList?
            /// Auftrag O/P2: the item description for the series/detail pages.
            let description: ArchiveStringList?
            /// The collections — the item's FORM is read from them, and on
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

    /// R46: how many items the query has IN TOTAL — the number a shelf
    /// heading has to name. Deliberately no second request: the stock rides
    /// along with the page we are fetching anyway.
    nonisolated static func decodeTotal(_ data: Data) throws -> Int? {
        try JSONDecoder().decode(SearchResponse.self, from: data).response?.numFound
    }

    /// E3: ONE curated classical query — the George-Blood 78rpm digitization
    /// project with the classical subject (4k+ clean single titles with
    /// composer metadata; probed against 78rpm/musopen/europeanlibraries —
    /// one good collection beats three noisy ones).
    /// The query itself now lives with the area data (`ArchiveMusicCatalog`)
    /// — one place for every archive.org music area.
    static var classicalQuery: String { ArchiveMusicCatalog.classical.query }

    /// Most-downloaded LibriVox items (the keyless popularity source).
    /// f374330: language filters SERVER-side (ISO-639-3 clause); an empty
    /// language result falls back to unfiltered (rule unchanged).
    static func popularLibriVox(rows: Int, languageCodes: [String] = [], page: Int = 1) async throws -> [ArchivePopularDoc] {
        if let clause = FreeCatalog.archiveLanguageClause(codes: languageCodes) {
            let filtered = try await popular(
                query: "collection:librivoxaudio AND \(clause)", rows: rows, page: page)
            if !filtered.isEmpty { return filtered }
            // Fallback only on the FIRST page — deeper pages legitimately end.
            guard page == 1 else { return [] }
        }
        return try await popular(query: "collection:librivoxaudio AND mediatype:(audio)", rows: rows, page: page)
    }

    /// 938aebc: popularity PER LANGUAGE, then interleaved. One combined
    /// query ranks by absolute download counts, where English buries every
    /// minority language — the measured effect behind "the row only ever
    /// shows English". Queries run concurrently; a failing language drops
    /// out instead of taking the row down with it.
    static func popularLibriVoxByLanguage(rowsPerLanguage: Int, languageCodes: [String],
                                          limit: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        let codes = languageCodes.isEmpty ? [""] : languageCodes
        // e9cf3be A6: per-language errors are collected — if EVERY language
        // fails, that is a row FAILURE and must throw, not collapse to [] (the
        // row vanished silently, neither content nor error line). A partial
        // failure stays best-effort: the surviving languages fill the row.
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

    /// e948444: Old Time Radio — the curated radio-play collection, but ONLY
    /// items with a stated licence. Measured 05.08.: 8.854 items total, 2.316
    /// with `licenseurl` (26 %). We do not suggest anything whose rights
    /// situation is unknown, and "no statement" is not "free".
    /// R47 (the owner's ENTSCHEID): der Lizenzfilter fiel vom ANZEIGE-Weg.
    /// „Auch die Sachen ohne Lizenzangabe mit reinnehmen — sie sind auf
    /// archive.org, dort wird alles frei zum Download angeboten." Wir zeigen
    /// und streamen, was dort oeffentlich liegt; ein Eintrag ohne Angabe
    /// traegt sichtbar „Rechtelage nicht angegeben" (nie gar nichts, nie eine
    /// Behauptung). Der Filter bleibt genau dort, wo er eine KOPIE schuetzt —
    /// siehe `mayDownload`.
    static let oldTimeRadioQuery = "collection:oldtimeradio"

    static func popularOldTimeRadio(rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popular(query: oldTimeRadioQuery, rows: rows, page: page)
    }

    /// bca2d20/0ce5df3: audiobooks in `audio_bookspoetry` OUTSIDE LibriVox.
    /// The triple filter is not a quality guard but the CORRECT QUERY — the
    /// same class as LibriVox new-arrivals and the genre-less charts:
    /// `mediatype:(audio)` (without it the collection returns TEXT items —
    /// Plato's "Republic" as EPUB, measured), a stated licence (we suggest
    /// nothing whose rights are unknown), and the language.
    ///
    /// Entdopplung (the measured finding): user-made compilations of
    /// LibriVox recordings slip through `NOT collection:librivoxaudio` — the
    /// identifier/creator carries "librivox", so it is excluded here rather
    /// than showing the same content twice.
    /// P1 (7e03298): the language fallback is a SESSION state, not a page
    /// property — the old first-page-only guard ended the 4,257-item trove
    /// after ~20 titles for German users (page 2 queried WITH the filter
    /// again, got nothing, read as reachedEnd). The pager passes the returned
    /// `unfiltered` back in, so deeper pages keep browsing the unfiltered
    /// corpus once the fallback happened (one truth, held by the caller).
    /// `fetch` is injectable so the decision chain is unit-testable.
    /// BEFUND f220ecd: the base query of a source lives in exactly ONE place.
    /// The shelf pages used to REBUILD it and thereby lost three decided
    /// points at once — the LibriVox de-duplication (1.098 of 1.602 hits were
    /// duplicates), the licence clause (178 titles without any rights
    /// statement) and, through `isCuratedArchiveDoc`, the MacLean denylist.
    /// A shelf appends its subject clause to THIS string; it never writes its
    /// own.
    /// R53: `.librivox` belongs here, and it did not — which is why the
    /// LibriVox page lost every shelf row. The query is the SAME one the
    /// popular row already falls back to (`popularLibriVox`), so the shelf,
    /// its chevron and the full page count one stock. No licence clause:
    /// LibriVox is public domain by source, and the popular row never carried
    /// one either — adding it here would silently shrink the shelves.
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
        // 9ef73a4 Befund 3: for German users this row was permanently EMPTY —
        // every German audiobook in the collection is a LibriVox title
        // (measured: (deu OR ger) with the NOT clause ⇒ 0, without ⇒ 844).
        if !unfiltered, let language = FreeCatalog.archiveLanguageClause(codes: languageCodes) {
            let filtered = try await fetch(base + " AND \(language)", rows, page)
            if !filtered.isEmpty { return (filtered.filter { FreeCatalog.isCuratedArchiveDoc($0) }, false) }
            // Filtered mode with stock on deeper pages legitimately ends.
            guard page == 1 else { return ([], false) }
        }
        let docs = try await fetch(base, rows, page)
        return (docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }, true)
    }

    /// E3: popular free classical recordings (same client, Regel 2).
    /// Netlabels/78s/classical all ride this ONE query path — the area
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

    /// Shared advancedsearch (downloads sort) — one mechanism for both rows.
    /// `sort` defaults to the popularity ranking; M2 passes "random" for the
    /// shuffle gesture (measured: the value works, but archive.org caches it
    /// for a few minutes — the caller varies the PAGE as well).
    /// R46: one page of a query PLUS the stock behind it. `popular` stays the
    /// name every caller knows and simply drops the number — one request, one
    /// truth, no second query path that could drift.
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
            // e948444: the licence rides along so the row can SHOW it.
            URLQueryItem(name: "fl[]", value: "licenseurl"),
            // ea6e002: the card's time line (present for most items).
            URLQueryItem(name: "fl[]", value: "runtime"),
            // 50aefa8: the recording year is the ONLY hint the user gets for
            // items whose rights status the source does not state (georgeblood
            // carries no licenceurl at all). Present for about a third of them
            // — measured, not assumed.
            URLQueryItem(name: "fl[]", value: "year"),
            // 48e786d: subjects ride along so the genre axis has material for
            // the archive.org rows too (they were never requested before).
            URLQueryItem(name: "fl[]", value: "subject"),
            // The collections decide the item's form (work in parts or album
            // of tracks). Requested here, in the one place every archive.org
            // row, shelf and search goes through — so an item carries its form
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
        // aed5d25: shared artifact filter for BOTH rows (books + classical) —
        // dropped docs are logged upstream via the count difference.
        do {
            let docs = try decodePopular(data).filter {
                !FreeCatalog.isArtifactDoc(identifier: $0.identifier, title: $0.title?.joined)
            }
            return (docs, try? decodeTotal(data))
        } catch {
            // 27f360b A3: a decode failure must be TELLABLE from transport —
            // archive.org can answer 200 with an HTML challenge. Carry status
            // and the first bytes of the answer (no URLs, so nothing to mask).
            let status = response?.statusCode
            let prefix = String(decoding: data.prefix(80), as: UTF8.self)
            throw FreeCatalog.CatalogDecodeError(status: status, answerPrefix: prefix)
        }
    }

    /// R47/„billiger Zug": the metadata WITHOUT the file list. archive.org
    /// serves a sub-path, and it is the difference between 1,36 MB and 8,3 kB
    /// (measured; 99 % of the full answer is the file list — for one OTR
    /// bundle 3.966 entries with checksums, plus 66 user reviews).
    ///
    /// Only ONE caller needs this shape: the detail sheet, which wants the
    /// description. Everything else needs the files, and for those the full
    /// answer IS the point — this is not a cheaper version of that call, it
    /// is a different question.
    static func metadataOnly(identifier: String) async throws -> MetadataResponse.Meta? {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)/metadata") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        // MEASURED, not assumed: the sub-path wraps its answer in `result`
        // (8.282 B against 1.359.765 B for the same item — factor 164).
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
        // 🟡 P10: this call is the place that LEARNS whether an item still
        // exists — every detail open and every playback start goes through
        // it. The three-way ladder decides what may be remembered; a
        // transport failure throws and remembers nothing (unknown).
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        DeadCatalogItems.note(
            DeadCatalogItems.liveness(httpStatus: response?.statusCode, body: data),
            for: identifier)
        return try JSONDecoder().decode(MetadataResponse.self, from: data)
    }

    /// The cheap liveness probe for the few PICKS a curated row shows — one
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

/// 0714d26 E2: Jamendo — client_id via BUILD INJECTION (never in the repo)
/// or the user's own key from the network-services page. No key → nil → the
/// row silently stays away (documented capability, not an error).
nonisolated enum JamendoClient {
    nonisolated struct TracksResponse: Decodable {
        let results: [JamendoTrack]?
    }

    /// Key resolution: user key beats the build-injected one — the shared Z1
    /// rule (`AppStorageKeys.resolvedAppKey`, same as PodcastIndex).
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
    /// track — the detail sheet carries both).
    /// P8: `tags` loads a genre shelf SERVER-side (fuzzytags, +-joined = OR —
    /// the API can do it better than filtering a local 200 pool); `offset`
    /// pages the shelf grid.
    static func popularTracks(limit: Int, tags: [String] = [],
                              offset: Int = 0) async throws -> [JamendoTrack] {
        guard let id = await clientId() else { return [] }
        var comp = URLComponents(string: "https://api.jamendo.com/v3.0/tracks/")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "popularity_week"),
            URLQueryItem(name: "audioformat", value: "mp32"),
        ]
        if !tags.isEmpty {
            comp.queryItems?.append(URLQueryItem(name: "fuzzytags", value: tags.joined(separator: "+")))
        }
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
