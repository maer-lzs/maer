// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit
import OSLog

/// A podcast search result from a directory — holds the feed URL that
/// `PodcastSubscriptions.subscribe(urlString:)` can subscribe to directly.
struct PodcastSearchResult: Identifiable {
    var title: String
    var author: String?
    var artworkURL: String?
    var feedURL: String
    /// Categories of the feed (PodcastIndex only) — for the recommendation ranking.
    var categories: [String]? = nil

    var id: String { feedURL }
}

/// A searchable podcast directory.
protocol PodcastDirectory {
    func search(_ term: String) async throws -> [PodcastSearchResult]
}

/// M5: curated podcast genres for the search browse chips. Charts come from
/// the KEYLESS iTunes genre charts (works regardless of which directory the
/// user configured for text search — honest capability: always available).
nonisolated struct PodcastGenre: Identifiable, Equatable {
    let itunesGenreId: Int
    let title: String
    let systemImage: String
    var id: Int { itunesGenreId }
}

nonisolated enum PodcastGenres {
    static let curated: [PodcastGenre] = [
        PodcastGenre(itunesGenreId: 1303, title: String(localized: "Comedy"), systemImage: "face.smiling"),
        PodcastGenre(itunesGenreId: 1489, title: String(localized: "News"), systemImage: "newspaper"),
        PodcastGenre(itunesGenreId: 1488, title: String(localized: "True Crime"), systemImage: "magnifyingglass"),
        PodcastGenre(itunesGenreId: 1324, title: String(localized: "Society & Culture"), systemImage: "person.2"),
        PodcastGenre(itunesGenreId: 1545, title: String(localized: "Sports"), systemImage: "sportscourt"),
        PodcastGenre(itunesGenreId: 1318, title: String(localized: "Technology"), systemImage: "cpu"),
        PodcastGenre(itunesGenreId: 1321, title: String(localized: "Business"), systemImage: "briefcase"),
        PodcastGenre(itunesGenreId: 1512, title: String(localized: "Health & Fitness"), systemImage: "heart"),
        PodcastGenre(itunesGenreId: 1533, title: String(localized: "Science"), systemImage: "atom"),
        PodcastGenre(itunesGenreId: 1487, title: String(localized: "History"), systemImage: "building.columns"),
        PodcastGenre(itunesGenreId: 1304, title: String(localized: "Education"), systemImage: "graduationcap"),
        // dd26a3c: Fiction plus its SUB-genres. Apple keeps radio plays apart
        // from the parent chart — the ARD Radio Tatort tops "Drama" and never
        // appears under "Fiction" alone. Measured on the DE storefront, so the
        // curated Hörspiel list stays a small socket instead of growing into a
        // hand-maintained duplicate of a query we already run.
        PodcastGenre(itunesGenreId: 1483, title: String(localized: "Fiction"), systemImage: "theatermasks"),
        PodcastGenre(itunesGenreId: 1484, title: String(localized: "Radio Play"), systemImage: "waveform.and.mic"),
        PodcastGenre(itunesGenreId: 1485, title: String(localized: "Science Fiction"), systemImage: "sparkles"),
        PodcastGenre(itunesGenreId: 1486, title: String(localized: "Comedy Fiction"), systemImage: "theatermasks.circle"),
    ]
}

// MARK: - iTunes / Apple (no key)

/// Apple's podcast search — keyless, returns the feed URL directly.
struct ITunesDirectory: PodcastDirectory {
    private struct Response: Decodable {
        struct Item: Decodable {
            let collectionName: String?
            let artistName: String?
            let artworkUrl600: String?
            let artworkUrl100: String?
            let feedUrl: String?
        }
        let results: [Item]
    }

    func search(_ term: String) async throws -> [PodcastSearchResult] {
        try await search(term, country: nil)
    }

    /// X²·3: the OERR live rule searches per broadcaster STOREFRONT — an
    /// explicit country overrides the suggestion-language default.
    func search(_ term: String, country: String?) async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        // f79c40c: the FIRST selected suggestion language sets the search
        // storefront (a per-keystroke multi-storefront fan-out would be
        // wasteful — honest simplification, reported; charts DO interleave).
        let storefront = country ?? SuggestionLanguages.storefront(
            for: SuggestionLanguages.current().first ?? "en")
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await RequestRetryPolicy.fetch(URLRequest(url: url))
        return Self.map(try JSONDecoder().decode(Response.self, from: data))
    }

    /// Top charts (fallback for "Discover" when no PodcastIndex key is set):
    /// iTunes top list → resolve feed URLs via batch lookup.
    func topPodcasts(limit: Int = 40) async throws -> [PodcastSearchResult] {
        try await topPodcasts(genreId: nil, limit: limit)
    }

    /// Pure (tested): the chart URL per storefront/genre — the suggestion-
    /// language wiring hangs off this one builder.
    nonisolated static func chartURL(storefront: String, genreId: Int?, limit: Int) -> URL? {
        let genrePart = genreId.map { "/genre=\($0)" } ?? ""
        return URL(string: "https://itunes.apple.com/\(storefront)/rss/toppodcasts/limit=\(limit)\(genrePart)/json")
    }

    /// M5 + f79c40c: the top chart narrowed to ONE genre (nil = all), results
    /// fairly interleaved and deduped by feed.
    ///
    /// 757e2eb: a language now spans SEVERAL storefronts (English deviates by
    /// up to 56 % between US and NZ), rotating per day so the request count
    /// stays flat while the variety arrives over the week. Each storefront is
    /// its own interleave lane — that way one market cannot dominate the row.
    func topPodcasts(genreId: Int?, limit: Int = 40) async throws -> [PodcastSearchResult] {
        let languages = SuggestionLanguages.current()
        var perLanguage: [[PodcastSearchResult]] = []
        var queried: [String] = []
        for language in languages.prefix(3) {
            for storefront in SuggestionLanguages.storefronts(for: language) {
                queried.append(storefront)
                perLanguage.append((try? await topPodcasts(storefront: storefront,
                                                           genreId: genreId, limit: limit)) ?? [])
            }
        }
        Logger.rss.notice("RECO charts genre=\(genreId.map(String.init) ?? "-", privacy: .public) storefronts=\(queried.joined(separator: ","), privacy: .public)")
        var seen = Set<String>()
        let mergedIds = HomeSections.interleave(perLanguage.map { $0.map(\.feedURL) }, limit: limit)
        let byFeed = Dictionary(perLanguage.flatMap { $0 }.map { ($0.feedURL, $0) },
                                uniquingKeysWith: { a, _ in a })
        return mergedIds.compactMap { seen.insert($0).inserted ? byFeed[$0] : nil }
    }

    private func topPodcasts(storefront: String, genreId: Int?, limit: Int) async throws -> [PodcastSearchResult] {
        guard let chartURL = ITunesDirectory.chartURL(storefront: storefront, genreId: genreId, limit: limit) else { return [] }
        let (data, _) = try await RequestRetryPolicy.fetch(URLRequest(url: chartURL))
        let ids = (try JSONDecoder().decode(ChartResponse.self, from: data)).feed.entry.map { $0.id.attributes.imId }
        guard !ids.isEmpty else { return [] }

        var comp = URLComponents(string: "https://itunes.apple.com/lookup")!
        comp.queryItems = [
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast")
        ]
        guard let lookupURL = comp.url else { return [] }
        let (ldata, _) = try await RequestRetryPolicy.fetch(URLRequest(url: lookupURL))
        return Self.map(try JSONDecoder().decode(Response.self, from: ldata))
    }

    private static func map(_ response: Response) -> [PodcastSearchResult] {
        response.results.compactMap { item in
            guard let feed = item.feedUrl else { return nil }
            return PodcastSearchResult(
                title: item.collectionName ?? feed,
                author: item.artistName,
                artworkURL: item.artworkUrl600 ?? item.artworkUrl100,
                feedURL: feed
            )
        }
    }

    /// Top-list feed: only the contained iTunes ids matter (`im:id`).
    private struct ChartResponse: Decodable {
        struct Feed: Decodable { let entry: [Entry] }
        struct Entry: Decodable {
            struct ID: Decodable { let attributes: Attributes }
            struct Attributes: Decodable {
                let imId: String
                enum CodingKeys: String, CodingKey { case imId = "im:id" }
            }
            let id: ID
        }
        let feed: Feed
    }
}

// MARK: - PodcastIndex (optionaler Key)

/// Open podcast catalog. Needs an API key + secret; requests are SHA1-signed
/// (key+secret+timestamp).
struct PodcastIndexDirectory: PodcastDirectory {
    let key: String
    let secret: String

    /// SHA1 hex of key+secret+date — the Authorization header. Extracted and
    /// unit-tested (signature errors would otherwise only surface at the server).
    /// `nonisolated`: pure hashing, callable from background/test contexts.
    nonisolated static func authHeader(key: String, secret: String, date: String) -> String {
        let hash = Insecure.SHA1.hash(data: Data((key + secret + date).utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private struct Response: Decodable {
        struct Feed: Decodable {
            let title: String?
            let author: String?
            let image: String?
            let url: String?
            let categories: [String: String]?   // {id: name}
        }
        let feeds: [Feed]
    }

    private static func map(_ feed: Response.Feed) -> PodcastSearchResult? {
        guard let feedURL = feed.url else { return nil }
        return PodcastSearchResult(
            title: feed.title ?? feedURL,
            author: feed.author,
            artworkURL: feed.image,
            feedURL: feedURL,
            categories: feed.categories.map { Array($0.values) }
        )
    }

    func search(_ term: String) async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm")!
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        guard let url = components.url else { return [] }
        let (data, _) = try await RequestRetryPolicy.fetch(signedRequest(url: url))
        return try JSONDecoder().decode(Response.self, from: data).feeds.compactMap(Self.map)
    }

    /// Trending podcasts (for "Discover"/recommendations). `lang` filters by
    /// language, `categories` by your interests (PodcastIndex `cat`).
    func trending(max: Int = 40, lang: String? = nil, categories: [String] = []) async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/podcasts/trending")!
        var q = [URLQueryItem(name: "max", value: String(max))]
        if let lang, !lang.isEmpty { q.append(URLQueryItem(name: "lang", value: lang)) }
        if !categories.isEmpty {
            q.append(URLQueryItem(name: "cat", value: categories.prefix(5).joined(separator: ",")))
        }
        components.queryItems = q
        guard let url = components.url else { return [] }
        let (data, _) = try await RequestRetryPolicy.fetch(signedRequest(url: url))
        return try JSONDecoder().decode(Response.self, from: data).feeds.compactMap(Self.map)
    }

    // MARK: - Episodes (full history)

    private struct EpisodesResponse: Decodable {
        struct Item: Decodable {
            let guid: String?
            let title: String?
            let description: String?
            let enclosureUrl: String?
            let datePublished: Double?   // Unix seconds
            let duration: Double?
            let image: String?
        }
        let items: [Item]
    }

    /// Episodes of a feed via PodcastIndex — often MORE COMPLETE than the live
    /// feed (the index keeps history). Up to `max` episodes in one call.
    func episodes(feedURL: String, max: Int = 1000) async throws -> [PodcastIndexEpisode] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/episodes/byfeedurl")!
        components.queryItems = [
            URLQueryItem(name: "url", value: feedURL),
            URLQueryItem(name: "max", value: String(max))
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await RequestRetryPolicy.fetch(signedRequest(url: url))
        let response = try JSONDecoder().decode(EpisodesResponse.self, from: data)
        return response.items.map {
            PodcastIndexEpisode(
                guid: $0.guid, title: $0.title, enclosureUrl: $0.enclosureUrl,
                datePublished: $0.datePublished, duration: $0.duration,
                description: $0.description, image: $0.image
            )
        }
    }

    /// Signed request (SHA1 hex of key+secret+unix seconds in the header).
    private func signedRequest(url: URL) -> URLRequest {
        let authDate = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(authDate, forHTTPHeaderField: "X-Auth-Date")
        request.setValue(Self.authHeader(key: key, secret: secret, date: authDate), forHTTPHeaderField: "Authorization")
        request.setValue("Maer/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// An episode from PodcastIndex (raw) — mapped by `PodcastSubscriptions` to the
/// stable `rss:<feedKey>:<guid>` id so it deduplicates with feed episodes and
/// uses the same progress key.
struct PodcastIndexEpisode {
    let guid: String?
    let title: String?
    let enclosureUrl: String?
    let datePublished: Double?
    let duration: Double?
    let description: String?
    let image: String?
}
