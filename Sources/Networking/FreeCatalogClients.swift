// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 0714d26 E1: the two KEYLESS free-audiobook services. Decode failures
/// THROW (badPayload-Lehre — never a silent empty row on a broken answer).
nonisolated enum LibriVoxClient {
    static let userAgent = "Maer/2.7 (https://codeberg.org/lzs/maer)"

    nonisolated static func decodeFeed(_ data: Data) throws -> [LibriVoxBook] {
        try JSONDecoder().decode(LibriVoxFeed.self, from: data).books ?? []
    }

    /// New catalog additions since `sinceDays` ago ("Neu bei LibriVox").
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
    static func audiobooks(languages: [String], page: Int = 1) async throws -> [Book] {
        var comp = URLComponents(string: "https://gutendex.com/books/")!
        var items = [URLQueryItem(name: "mime_type", value: "audio/mpeg"),
                     URLQueryItem(name: "page", value: String(page))]
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
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
    static let classicalQuery = "collection:georgeblood AND subject:classical AND mediatype:(audio)"

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
    /// Entdopplung (the reviewer's measured finding): user-made compilations of
    /// LibriVox recordings slip through `NOT collection:librivoxaudio` — the
    /// identifier/creator carries "librivox", so it is excluded here rather
    /// than showing the same content twice.
    static func audiobooksOutsideLibriVox(rows: Int, languageCodes: [String],
                                          page: Int = 1) async throws -> [ArchivePopularDoc] {
        let base = "collection:audio_bookspoetry AND NOT collection:librivoxaudio"
            + " AND mediatype:(audio) AND licenseurl:[* TO *]"
        // 9ef73a4 Befund 3: for German users this row was permanently EMPTY —
        // every German audiobook in the collection is a LibriVox title
        // (measured: (deu OR ger) with the NOT clause ⇒ 0, without ⇒ 844), and
        // unlike the LibriVox row this one never fell back. Same rule now,
        // same reasoning ("an empty row would be worse"), same shape as
        // popularLibriVox: fall back to unfiltered on the FIRST page only —
        // deeper pages legitimately end.
        if let language = FreeCatalog.archiveLanguageClause(codes: languageCodes) {
            let filtered = try await popular(query: base + " AND \(language)", rows: rows, page: page)
            if !filtered.isEmpty { return filtered.filter { FreeCatalog.isNotLibriVoxDuplicate($0) } }
            guard page == 1 else { return [] }
        }
        let docs = try await popular(query: base, rows: rows, page: page)
        return docs.filter { FreeCatalog.isNotLibriVoxDuplicate($0) }
    }

    /// E3: popular free classical recordings (same client, Regel 2).
    static func popularClassical(rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
        try await popular(query: classicalQuery, rows: rows, page: page)
    }

    /// Shared advancedsearch (downloads sort) — one mechanism for both rows.
    static func popular(query: String, rows: Int, page: Int = 1) async throws -> [ArchivePopularDoc] {
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
            URLQueryItem(name: "sort[]", value: "downloads desc"),
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
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try JSONDecoder().decode(MetadataResponse.self, from: data)
    }
}

/// 0714d26 E2: Jamendo — client_id via BUILD INJECTION (never in the repo)
/// or the user's own key from the network-services page. No key → nil → the
/// row silently stays away (documented capability, not an error).
nonisolated enum JamendoClient {
    nonisolated struct TracksResponse: Decodable {
        let results: [JamendoTrack]?
    }

    /// Key resolution: user key beats the build-injected one (PI pattern).
    @MainActor
    static func clientId() -> String? {
        if let user = UserDefaults.standard.string(forKey: AppStorageKeys.jamendoClientId),
           !user.isEmpty { return user }
        if let injected = Bundle.main.object(forInfoDictionaryKey: "JamendoClientId") as? String,
           !injected.isEmpty { return injected }
        return nil
    }

    nonisolated static func decodeTracks(_ data: Data) throws -> [JamendoTrack] {
        try JSONDecoder().decode(TracksResponse.self, from: data).results ?? []
    }

    /// Weekly popularity chart (CC music; ToS: attribution + backlink per
    /// track — the detail sheet carries both).
    static func popularTracks(limit: Int) async throws -> [JamendoTrack] {
        guard let id = await clientId() else { return [] }
        var comp = URLComponents(string: "https://api.jamendo.com/v3.0/tracks/")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "popularity_week"),
            URLQueryItem(name: "audioformat", value: "mp32"),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        return try decodeTracks(data)
    }
}
