import Foundation
import Combine

/// Eine abonnierte Show mit ihren Episoden (persistiert, damit die letzten
/// Folgen offline sichtbar bleiben).
nonisolated struct PodcastShow: Codable, Identifiable {
    var id: String                 // stabile Feed-ID (aus der URL abgeleitet)
    var title: String
    var author: String?
    var artworkURL: String?
    var description: String?
    var feedURL: String
    var episodes: [PodcastEpisode]
}

nonisolated struct PodcastEpisode: Codable, Identifiable {
    var guid: String
    var title: String
    var audioURL: String
    var pubDate: Double             // ms epoch
    var duration: Double            // Sekunden (0 wenn unbekannt)
    var description: String?
    var imageURL: String?

    var id: String { guid }
}

/// Verwaltung der Podcast-Abos: Feeds hinzufügen/entfernen, aktualisieren
/// (RSS/Atom per XMLParser, ohne Fremd-Abhängigkeit), persistenter Cache.
/// Reines Quellen-Backend hinter dem `RSSProvider` — der Core spricht nur
/// mit dem Provider, nie direkt hiermit (nur die Verwaltungs-UI tut das).
@MainActor
final class PodcastSubscriptions: ObservableObject {
    static let shared = PodcastSubscriptions()

    @Published private(set) var shows: [PodcastShow] = []

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("podcast_subscriptions.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PodcastShow].self, from: data) {
            shows = decoded
        }
    }

    var hasSubscriptions: Bool { !shows.isEmpty }

    // MARK: - Abos

    /// Feed abonnieren (lädt + parst sofort). Bereits vorhandene Feeds werden
    /// nur aktualisiert.
    func subscribe(urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return false }
        guard let show = await Self.fetchAndParse(feedURL: url) else { return false }
        if let idx = shows.firstIndex(where: { $0.id == show.id }) {
            shows[idx] = show
        } else {
            shows.insert(show, at: 0)
        }
        save()
        return true
    }

    func unsubscribe(id: String) {
        shows.removeAll { $0.id == id }
        save()
    }

    /// Alle Feeds neu laden (Pull-to-refresh). Fehlgeschlagene behalten ihren
    /// Cache-Stand.
    func refreshAll() async {
        var updated = shows
        for (index, show) in shows.enumerated() {
            if let url = URL(string: show.feedURL), let fresh = await Self.fetchAndParse(feedURL: url) {
                updated[index] = fresh
            }
        }
        shows = updated
        save()
    }

    // MARK: - Abfragen für den Provider

    /// Alle Episoden aller Shows, neueste zuerst.
    func allEpisodes() -> [(show: PodcastShow, episode: PodcastEpisode)] {
        shows.flatMap { show in show.episodes.map { (show, $0) } }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
    }

    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        for show in shows {
            if let ep = show.episodes.first(where: { $0.guid == guid }) { return (show, ep) }
        }
        return nil
    }

    // MARK: - Persistenz

    private func save() {
        guard let data = try? JSONEncoder().encode(shows) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func normalizedFeedURL(_ raw: String) -> URL? {
        var s = raw
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        return URL(string: s)
    }

    // MARK: - Laden + Parsen

    private nonisolated static func fetchAndParse(feedURL: URL) async -> PodcastShow? {
        guard let (data, _) = try? await URLSession.shared.data(from: feedURL) else { return nil }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        return parser.parse(data)
    }
}

/// Minimaler RSS/Atom-Parser auf Basis von `XMLParser`. Deckt die iTunes-
/// Podcast-Felder ab; unbekannte Tags werden ignoriert, kaputte Items
/// übersprungen. Internal (nicht private) — mit Unit-Tests abgedeckt.
final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    init(feedURL: String) { self.feedURL = feedURL }

    private var showTitle = ""
    private var showAuthor: String?
    private var showImage: String?
    private var showDescription: String?

    private var episodes: [PodcastEpisode] = []
    private var inItem = false
    private var text = ""

    // Aktuelles Item
    private var iTitle = "", iGuid = "", iAudio = "", iDuration = "", iDesc = "", iImage = "", iPubDate = ""

    func parse(_ data: Data) -> PodcastShow? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !showTitle.isEmpty || !episodes.isEmpty else { return nil }
        return PodcastShow(
            id: "feed:\(feedURL.hashValue)",
            title: showTitle.isEmpty ? feedURL : showTitle,
            author: showAuthor,
            artworkURL: showImage,
            description: showDescription,
            feedURL: feedURL,
            episodes: episodes
        )
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        text = ""
        if el == "item" || el == "entry" {
            inItem = true
            iTitle = ""; iGuid = ""; iAudio = ""; iDuration = ""; iDesc = ""; iImage = ""; iPubDate = ""
        }
        // Enclosure (RSS) bzw. Media/Link mit Audio-Typ
        if el == "enclosure", let url = attrs["url"], (attrs["type"]?.hasPrefix("audio") ?? true) {
            iAudio = url
        }
        // itunes:image / channel image via href-Attribut
        if el == "itunes:image", let href = attrs["href"] {
            if inItem { iImage = href } else if showImage == nil { showImage = href }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch el {
            case "title": iTitle = value
            case "guid", "id": if iGuid.isEmpty { iGuid = value }
            case "itunes:duration": iDuration = value
            case "description", "itunes:summary", "content:encoded": if iDesc.isEmpty { iDesc = value }
            case "pubDate", "published": iPubDate = value
            case "item", "entry":
                inItem = false
                if !iAudio.isEmpty {
                    episodes.append(PodcastEpisode(
                        guid: "rss:\(feedURL.hashValue):\(iGuid.isEmpty ? iAudio : iGuid)",
                        title: iTitle.isEmpty ? String(localized: "Untitled Episode") : iTitle,
                        audioURL: iAudio,
                        pubDate: Self.parseDate(iPubDate),
                        duration: Self.parseDuration(iDuration),
                        description: iDesc.isEmpty ? nil : iDesc,
                        imageURL: iImage.isEmpty ? nil : iImage
                    ))
                }
            default: break
            }
        } else {
            switch el {
            case "title": if showTitle.isEmpty { showTitle = value }
            case "itunes:author": showAuthor = value
            case "description", "itunes:summary": if showDescription == nil { showDescription = value }
            default: break
            }
        }
        text = ""
    }

    // RFC822-Datum → ms epoch (Fallback: 0).
    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static func parseDate(_ s: String) -> Double {
        if let d = rfc822.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        if let d = ISO8601DateFormatter().date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    // "HH:MM:SS", "MM:SS" oder reine Sekunden → Sekunden.
    private static func parseDuration(_ s: String) -> Double {
        if s.contains(":") {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(s) ?? 0
    }
}
