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

    /// R1 (09.08., gemessen): the API filters by genre (`genre=`, case-
    /// insensitive) and pages (`offset=`) — that is what turns a shelf from a
    /// 20-title pool filter into its real stock (Poetry ≥1.200, Philosophy
    /// 281). Past the end the API answers **404**; that is the END signal,
    /// not a failure, so it maps to an empty page instead of an error.
    static func books(genre: String, limit: Int, offset: Int = 0) async throws -> [LibriVoxBook] {
        var comp = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "genre", value: genre),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        if response?.statusCode == 404 { return [] }   // end of list, not a failure
        return try decodeFeed(data)
    }

    static func newBooks(sinceDays: Int, limit: Int) async throws -> [LibriVoxBook] {
        let since = Int(Date().timeIntervalSince1970) - sinceDays * 86_400
        var comp = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "since", value: String(since)),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
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
    nonisolated struct Book: Decodable, Sendable {
        let id: Int
        let title: String?
        let authors: [Author]?
        let languages: [String]?
        let formats: [String: String]?
        /// 48e786d: gutendex delivers `subjects` as plain strings — passed on
        /// so the genre axis has material here too.
        let subjects: [String]?

        nonisolated struct Author: Decodable, Sendable { let name: String? }
    }

    nonisolated struct Response: Decodable, Sendable {
        let count: Int?
        let results: [Book]?
    }

    nonisolated static func decode(_ data: Data) throws -> [Book] {
        try JSONDecoder().decode(Response.self, from: data).results ?? []
    }

    /// Audiobooks in the given languages. Gutendex pages at 32 entries; the
    /// caller decides how many pages are worth it.
    /// `topic` (R1) filters server-side over subjects AND bookshelves —
    /// measured 09.08.: philosophy 13, religion 3. Small, but that IS the
    /// stock; the shelf shows honestly what exists.
    static func audiobooks(languages: [String], page: Int = 1,
                           search: String? = nil, topic: String? = nil) async throws -> [Book] {
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
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decode(data)
    }
}

nonisolated enum ArchiveOrgClient {
    nonisolated struct SearchResponse: Decodable {
        struct Body: Decodable { let docs: [ArchivePopularDoc]? }
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
    static let oldTimeRadioQuery = "collection:oldtimeradio AND licenseurl:[* TO *]"

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
    static func archiveBaseQuery(for source: CatalogSource) -> String? {
        switch source {
        case .archiveBooks:
            "collection:audio_bookspoetry AND NOT collection:librivoxaudio"
                + " AND mediatype:(audio) AND licenseurl:[* TO *]"
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

    private static func popularArchiveMusic(query: String, rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popular(query: query, rows: rows, page: page)
    }

    /// Shared advancedsearch (downloads sort) — one mechanism for both rows.
    /// `sort` defaults to the popularity ranking; M2 passes "random" for the
    /// shuffle gesture (measured: the value works, but archive.org caches it
    /// for a few minutes — the caller varies the PAGE as well).
    static func popular(query: String, rows: Int, page: Int = 1,
                        sort: String = "downloads desc") async throws -> [ArchivePopularDoc] {
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
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await RequestRetryPolicy.fetch(request)
        // aed5d25: shared artifact filter for BOTH rows (books + classical) —
        // dropped docs are logged upstream via the count difference.
        do {
            return try decodePopular(data).filter {
                !FreeCatalog.isArtifactDoc(identifier: $0.identifier, title: $0.title?.joined)
            }
        } catch {
            // 27f360b A3: a decode failure must be TELLABLE from transport —
            // archive.org can answer 200 with an HTML challenge. Carry status
            // and the first bytes of the answer (no URLs, so nothing to mask).
            let status = response?.statusCode
            let prefix = String(decoding: data.prefix(80), as: UTF8.self)
            throw FreeCatalog.CatalogDecodeError(status: status, answerPrefix: prefix)
        }
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
