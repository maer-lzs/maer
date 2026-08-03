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
        let lists: [[ArchivePopularDoc]] = await withTaskGroup(of: (Int, [ArchivePopularDoc]).self) { group in
            for (index, code) in codes.enumerated() {
                group.addTask {
                    let docs = try? await popularLibriVox(
                        rows: rowsPerLanguage,
                        languageCodes: code.isEmpty ? [] : [code], page: page)
                    return (index, docs ?? [])
                }
            }
            var byIndex: [Int: [ArchivePopularDoc]] = [:]
            for await (index, docs) in group { byIndex[index] = docs }
            return codes.indices.map { byIndex[$0] ?? [] }
        }
        return FreeCatalog.interleaveByLanguage(lists, limit: limit) { $0.identifier ?? "" }
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
            // ea6e002: the card's time line (present for most items).
            URLQueryItem(name: "fl[]", value: "runtime"),
            URLQueryItem(name: "sort[]", value: "downloads desc"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = comp.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await RequestRetryPolicy.fetch(request)
        // aed5d25: shared artifact filter for BOTH rows (books + classical) —
        // dropped docs are logged upstream via the count difference.
        return try decodePopular(data).filter {
            !FreeCatalog.isArtifactDoc(identifier: $0.identifier, title: $0.title?.joined)
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
