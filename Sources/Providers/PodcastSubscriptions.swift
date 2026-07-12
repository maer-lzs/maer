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

    @Published private(set) var shows: [PodcastShow] = [] {
        didSet { rebuildCaches() }
    }

    /// guid → (Show-Index, Episoden-Index) für O(1)-Lookup statt linearer Suche
    /// über alle Folgen (die pro Cover-Zelle lief und nach dem Import bremste).
    private var episodeIndex: [String: (show: Int, episode: Int)] = [:]
    /// Gecachte, sortierte Gesamtliste (invalidiert bei `shows`-Änderung).
    private var cachedAllEpisodes: [(show: PodcastShow, episode: PodcastEpisode)]?

    private func rebuildCaches() {
        cachedAllEpisodes = nil
        var index: [String: (Int, Int)] = [:]
        index.reserveCapacity(shows.reduce(0) { $0 + $1.episodes.count })
        for (s, show) in shows.enumerated() {
            for (e, ep) in show.episodes.enumerated() { index[ep.guid] = (s, e) }
        }
        episodeIndex = index
    }

    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("podcast_subscriptions.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([PodcastShow].self, from: data) {
            shows = migrated(decoded)
        }
    }

    var hasSubscriptions: Bool { !shows.isEmpty }

    // MARK: - Stabile ids + Dedup (Migration)

    /// Deterministischer Schlüssel eines Feeds (FNV‑1a hex über die
    /// normalisierte URL). Ersetzt das früher genutzte `String.hashValue`, das
    /// pro App-Start neu geseedet war und so Duplikate + Fortschrittsverlust
    /// verursacht hat.
    nonisolated static func feedKey(_ feedURL: String) -> String {
        stableHash(normalizeFeedURL(feedURL))
    }

    nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603          // FNV offset basis
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }   // FNV prime
        return String(h, radix: 16)
    }

    /// Feed-URLs vergleichbar machen (Schema/`www.`/Query/Trailing-Slash egal),
    /// damit http/https- bzw. Slash-Varianten desselben Feeds zusammenfallen.
    nonisolated static func normalizeFeedURL(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Persistierte Shows auf stabile ids/guids bringen und Doppel-Shows
    /// (gleiche normalisierte Feed-URL) zusammenführen. Idempotent — spätere
    /// Starts ändern nichts mehr. Beim Umschlüsseln der guids wandert der
    /// zugehörige `localPosition`-Fortschritt mit (alt→neu), damit der gerade
    /// importierte Apple-Fortschritt erhalten bleibt.
    private func migrated(_ decoded: [PodcastShow]) -> [PodcastShow] {
        var byKey: [String: PodcastShow] = [:]
        var order: [String] = []
        var changed = false

        for show in decoded {
            let key = Self.feedKey(show.feedURL)
            var rebuilt = show
            rebuilt.id = "feed:\(key)"
            if rebuilt.id != show.id { changed = true }
            rebuilt.episodes = show.episodes.map { ep in
                var e = ep
                let newGuid = "rss:\(key):\(Self.originalGuid(ep.guid))"
                if newGuid != ep.guid {
                    Self.migrateLocalPosition(from: ep.guid, to: newGuid)
                    e.guid = newGuid
                    changed = true
                }
                return e
            }

            if let existing = byKey[key] {
                byKey[key] = Self.merge(existing, rebuilt)
                changed = true
            } else {
                byKey[key] = rebuilt
                order.append(key)
            }
        }

        let result = order.compactMap { byKey[$0] }
        if changed {
            // Direkt zurückschreiben, damit die Bereinigung persistent ist.
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        return result
    }

    /// Aus `rss:<hash>:<original>` den ursprünglichen guid herauslösen
    /// (der selbst Doppelpunkte enthalten kann → maxSplits 2).
    private nonisolated static func originalGuid(_ guid: String) -> String {
        let parts = guid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "rss" { return String(parts[2]) }
        return guid
    }

    /// Zwei Shows desselben Feeds vereinen: Metadaten der reicheren behalten,
    /// Episoden nach guid deduplizieren, neueste zuerst.
    private nonisolated static func merge(_ a: PodcastShow, _ b: PodcastShow) -> PodcastShow {
        let (base, other) = a.episodes.count >= b.episodes.count ? (a, b) : (b, a)
        var result = base
        var seen = Set(base.episodes.map { $0.guid })
        let extra = other.episodes.filter { seen.insert($0.guid).inserted }
        result.episodes = (base.episodes + extra).sorted { $0.pubDate > $1.pubDate }
        return result
    }

    /// `localPosition.<altGuid>` → `<neuGuid>` umziehen (nur wenn Ziel leer).
    private nonisolated static func migrateLocalPosition(from old: String, to new: String) {
        let d = UserDefaults.standard
        let oldKey = AppStorageKeys.localPosition(old)
        let newKey = AppStorageKeys.localPosition(new)
        guard d.object(forKey: newKey) == nil, let value = d.array(forKey: oldKey) else { return }
        d.set(value, forKey: newKey)
        d.removeObject(forKey: oldKey)
    }

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

    /// Volle Historie einer Show über PodcastIndex nachladen (wenn Key
    /// hinterlegt) und in die persistierten Folgen mergen. Gleiche
    /// `rss:<feedKey>:<guid>`-IDs wie der Feed → Dedup + gemeinsamer
    /// Fortschritts-Key. Rückgabe: Zahl NEU hinzugekommener Folgen.
    func loadFullHistory(showId: String) async -> Int {
        guard AppStorageKeys.podcastIndexConfigured,
              let idx = shows.firstIndex(where: { $0.id == showId }) else { return 0 }
        let show = shows[idx]
        let dir = PodcastIndexDirectory(
            key: UserDefaults.standard.string(forKey: AppStorageKeys.podcastIndexKey) ?? "",
            secret: UserDefaults.standard.string(forKey: AppStorageKeys.podcastIndexSecret) ?? ""
        )
        guard let piEpisodes = try? await dir.episodes(feedURL: show.feedURL) else { return 0 }
        let key = Self.feedKey(show.feedURL)
        var seen = Set(show.episodes.map { $0.guid })
        var added: [PodcastEpisode] = []
        for pi in piEpisodes {
            guard let audio = pi.enclosureUrl, !audio.isEmpty else { continue }
            let guid = "rss:\(key):\(pi.guid ?? audio)"   // wie RSSFeedParser
            guard seen.insert(guid).inserted else { continue }
            added.append(PodcastEpisode(
                guid: guid,
                title: pi.title ?? String(localized: "Untitled Episode"),
                audioURL: audio,
                pubDate: (pi.datePublished ?? 0) * 1000,
                duration: pi.duration ?? 0,
                description: pi.description,
                imageURL: pi.image
            ))
        }
        guard !added.isEmpty else { return 0 }
        shows[idx].episodes = (show.episodes + added).sorted { $0.pubDate > $1.pubDate }
        save()
        return added.count
    }

    // MARK: - Import (OPML / Apple Podcasts)

    /// Ergebnis eines Imports fürs UI-Feedback.
    struct ImportResult {
        var subscribed = 0        // neu/aktualisiert abonniert
        var failed = 0            // Feed nicht ladbar
        var progressApplied = 0   // Episoden mit übernommenem Fortschritt/Gehört
    }

    /// OPML-Datei importieren: jeden `xmlUrl`-Feed abonnieren (kein Fortschritt).
    func importOPML(_ data: Data) async -> ImportResult {
        var result = ImportResult()
        for feed in PodcastImport.parseOPML(data) {
            if await subscribe(urlString: feed) { result.subscribed += 1 } else { result.failed += 1 }
        }
        return result
    }

    /// Apple-Podcasts-`MTLibrary.sqlite` importieren: Abos + Fortschritt + Gehört.
    /// `nil`, wenn die Datei nicht als SQLite geöffnet werden kann.
    func importAppleLibrary(at url: URL) async -> ImportResult? {
        // SQLite-Read vom MainActor weg (kann bei großer DB dauern); der
        // Security-Scope-Zugriff der aufrufenden View gilt prozessweit.
        guard let library = await Task.detached(priority: .userInitiated, operation: {
            PodcastImport.readAppleLibrary(at: url)
        }).value else { return nil }
        var result = ImportResult()
        for feed in library.feedURLs {
            if await subscribe(urlString: feed) { result.subscribed += 1 } else { result.failed += 1 }
        }
        result.progressApplied = applyAppleProgress(library.progress)
        return result
    }

    /// Bildet Apples Enclosure-URLs auf unsere Episoden ab und schreibt deren
    /// Fortschritt in `localPosition` (dieselbe Ablage, die der Player nutzt).
    private func applyAppleProgress(_ progress: [PodcastImport.AppleProgress]) -> Int {
        guard !progress.isEmpty else { return 0 }
        // Nach normalisierter Enclosure-URL indizieren (Query/Scheme egal).
        var byURL: [String: PodcastImport.AppleProgress] = [:]
        for p in progress { byURL[Self.normalizeEnclosure(p.enclosureURL)] = p }

        var updated = shows
        var applied = 0
        for s in updated.indices {
            for e in updated[s].episodes.indices {
                let episode = updated[s].episodes[e]
                guard let match = byURL[Self.normalizeEnclosure(episode.audioURL)] else { continue }
                // Fehlt die Dauer im Feed (kein `itunes:duration`), die von Apple
                // übernehmen — sonst kann „gehört" (time ≥ duration−1) nie greifen.
                if episode.duration <= 0, match.duration > 0 {
                    updated[s].episodes[e].duration = match.duration
                }
                let duration = updated[s].episodes[e].duration
                let time = match.isPlayed ? max(duration, match.playhead) : match.playhead
                guard time > 1 else { continue }
                UserDefaults.standard.set(
                    [time, Date().timeIntervalSince1970 * 1000],
                    forKey: AppStorageKeys.localPosition(episode.guid)
                )
                applied += 1
            }
        }
        if applied > 0 {
            shows = updated   // ggf. korrigierte Dauern übernehmen (didSet baut Index neu)
            save()
            PodcastProgressStore.shared.reload()
        }
        return applied
    }

    /// Enclosure-URLs vergleichbar machen: Query & Scheme raus, klein, /-trim.
    private nonisolated static func normalizeEnclosure(_ raw: String) -> String {
        var s = raw.lowercased()
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        s = s.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        while s.hasSuffix("/") { s.removeLast() }
        return s
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

    /// Alle Episoden aller Shows, neueste zuerst (gecacht — pro Render sonst
    /// mehrfach neu sortiert).
    func allEpisodes() -> [(show: PodcastShow, episode: PodcastEpisode)] {
        if let cached = cachedAllEpisodes { return cached }
        let all = shows.flatMap { show in show.episodes.map { (show: show, episode: $0) } }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
        cachedAllEpisodes = all
        return all
    }

    /// O(1)-Lookup über den guid-Index.
    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        guard let (s, e) = episodeIndex[guid],
              s < shows.count, e < shows[s].episodes.count else { return nil }
        return (shows[s], shows[s].episodes[e])
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
        guard let (data, _) = try? await URLSession.maer.data(from: feedURL) else { return nil }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        return parser.parse(data)
    }
}

/// Minimaler RSS/Atom-Parser auf Basis von `XMLParser`. Deckt die iTunes-
/// Podcast-Felder ab; unbekannte Tags werden ignoriert, kaputte Items
/// übersprungen. Internal (nicht private) — mit Unit-Tests abgedeckt.
final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    /// Stabiler, deterministischer Feed-Schlüssel (NICHT `String.hashValue`,
    /// das pro App-Start neu geseedet ist) — Basis für Show-id und guids.
    private let feedKey: String
    init(feedURL: String) {
        self.feedURL = feedURL
        self.feedKey = PodcastSubscriptions.feedKey(feedURL)
    }

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
            id: "feed:\(feedKey)",
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
                        guid: "rss:\(feedKey):\(iGuid.isEmpty ? iAudio : iGuid)",
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
