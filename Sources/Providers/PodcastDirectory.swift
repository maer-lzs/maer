import Foundation
import CryptoKit

/// Ein Podcast-Suchtreffer aus einem Verzeichnis — enthält die Feed-URL, mit
/// der `PodcastSubscriptions.subscribe(urlString:)` direkt abonnieren kann.
struct PodcastSearchResult: Identifiable {
    var title: String
    var author: String?
    var artworkURL: String?
    var feedURL: String

    var id: String { feedURL }
}

/// Ein durchsuchbares Podcast-Verzeichnis.
protocol PodcastDirectory {
    func search(_ term: String) async throws -> [PodcastSearchResult]
}

// MARK: - iTunes / Apple (kein Key)

/// Apples Podcast-Suche — schlüssellos, liefert die Feed-URL direkt.
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
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.maer.data(from: url)
        return Self.map(try JSONDecoder().decode(Response.self, from: data))
    }

    /// Top-Charts (Fallback für „Entdecken", wenn kein PodcastIndex-Key gesetzt
    /// ist): iTunes-Toplist → Feed-URLs per Batch-Lookup nachziehen.
    func topPodcasts(limit: Int = 40) async throws -> [PodcastSearchResult] {
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        guard let chartURL = URL(string: "https://itunes.apple.com/\(region)/rss/toppodcasts/limit=\(limit)/json") else { return [] }
        let (data, _) = try await URLSession.maer.data(from: chartURL)
        let ids = (try JSONDecoder().decode(ChartResponse.self, from: data)).feed.entry.map { $0.id.attributes.imId }
        guard !ids.isEmpty else { return [] }

        var comp = URLComponents(string: "https://itunes.apple.com/lookup")!
        comp.queryItems = [
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "entity", value: "podcast")
        ]
        guard let lookupURL = comp.url else { return [] }
        let (ldata, _) = try await URLSession.maer.data(from: lookupURL)
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

    /// Toplist-Feed: nur die enthaltenen iTunes-IDs interessieren (`im:id`).
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

/// Offener Podcast-Katalog. Braucht API-Key + Secret; Requests sind
/// SHA1-signiert (Key+Secret+Zeitstempel).
struct PodcastIndexDirectory: PodcastDirectory {
    let key: String
    let secret: String

    /// SHA1-Hex von Key+Secret+Datum — der Authorization-Header. Ausgelagert
    /// und unit-getestet (Signatur-Fehler fallen sonst erst am Server auf).
    static func authHeader(key: String, secret: String, date: String) -> String {
        let hash = Insecure.SHA1.hash(data: Data((key + secret + date).utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private struct Response: Decodable {
        struct Feed: Decodable {
            let title: String?
            let author: String?
            let image: String?
            let url: String?
        }
        let feeds: [Feed]
    }

    func search(_ term: String) async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/search/byterm")!
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.maer.data(for: signedRequest(url: url))
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.feeds.compactMap { feed in
            guard let feedURL = feed.url else { return nil }
            return PodcastSearchResult(
                title: feed.title ?? feedURL,
                author: feed.author,
                artworkURL: feed.image,
                feedURL: feedURL
            )
        }
    }

    /// Trending-Podcasts (für „Entdecken"). Gleiche Feed-Form wie die Suche.
    func trending(max: Int = 40, lang: String? = "en") async throws -> [PodcastSearchResult] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/podcasts/trending")!
        var q = [URLQueryItem(name: "max", value: String(max))]
        if let lang { q.append(URLQueryItem(name: "lang", value: lang)) }
        components.queryItems = q
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.maer.data(for: signedRequest(url: url))
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.feeds.compactMap { feed in
            guard let feedURL = feed.url else { return nil }
            return PodcastSearchResult(
                title: feed.title ?? feedURL,
                author: feed.author,
                artworkURL: feed.image,
                feedURL: feedURL
            )
        }
    }

    // MARK: - Episoden (volle Historie)

    private struct EpisodesResponse: Decodable {
        struct Item: Decodable {
            let guid: String?
            let title: String?
            let description: String?
            let enclosureUrl: String?
            let datePublished: Double?   // Unix-Sekunden
            let duration: Double?
            let image: String?
        }
        let items: [Item]
    }

    /// Folgen eines Feeds über PodcastIndex — oft VOLLSTÄNDIGER als der Live-Feed
    /// (der Index speichert Historie). Bis zu `max` Folgen in einem Call.
    func episodes(feedURL: String, max: Int = 1000) async throws -> [PodcastIndexEpisode] {
        var components = URLComponents(string: "https://api.podcastindex.org/api/1.0/episodes/byfeedurl")!
        components.queryItems = [
            URLQueryItem(name: "url", value: feedURL),
            URLQueryItem(name: "max", value: String(max))
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.maer.data(for: signedRequest(url: url))
        let response = try JSONDecoder().decode(EpisodesResponse.self, from: data)
        return response.items.map {
            PodcastIndexEpisode(
                guid: $0.guid, title: $0.title, enclosureUrl: $0.enclosureUrl,
                datePublished: $0.datePublished, duration: $0.duration,
                description: $0.description, image: $0.image
            )
        }
    }

    /// Signierter Request (SHA1-Hex von Key+Secret+Unix-Sekunden im Header).
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

/// Eine Folge aus PodcastIndex (roh) — wird von `PodcastSubscriptions` mit der
/// stabilen `rss:<feedKey>:<guid>`-ID gemappt, damit sie mit Feed-Folgen
/// dedupliziert und denselben Fortschritts-Key nutzt.
struct PodcastIndexEpisode {
    let guid: String?
    let title: String?
    let enclosureUrl: String?
    let datePublished: Double?
    let duration: Double?
    let description: String?
    let image: String?
}
