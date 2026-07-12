import Foundation
import Combine

/// Eine Feed-Folge (roh vom Server geparst), die noch nicht in der Library
/// liegt und server-seitig nachgeladen werden kann. `raw` wird 1:1 an
/// `download-episodes` zurückgegeben (der Server erwartet sein Feed-Format).
struct FeedEpisode: Identifiable {
    let id: String
    let title: String
    let publishedAt: Double
    let duration: Double
    let enclosureUrl: String
    let raw: [String: Any]
}

/// Audiobookshelf-Podcasts als eigene Quelle vom Typ `.podcasts`. Anders als
/// der Haupt-ABS-Provider (Hörbücher, rohe IDs) namespaced dieser Provider
/// seine IDs mit `abspod:<libraryItemId>:<episodeId>` — eine Episode ist die
/// abspielbare Einheit. Nutzt den geteilten `APIClient` (Netzwerk/Auth) und
/// hängt sich über `.progressSync` in die bestehende Sync-Maschinerie ein →
/// Fortschritt/Gehört pro Episode syncen server-seitig über alle Geräte.
@MainActor
final class ABSPodcastProvider: ObservableObject, AudioProvider {
    static let shared = ABSPodcastProvider()
    private init() {
        archivedShowIds = Set(UserDefaults.standard.stringArray(forKey: Self.archiveKey) ?? [])
    }

    private static let archiveKey = "abspod.archivedShows"

    private var client: APIClient { AppSession.shared.apiClient }

    /// Geladene Shows samt Folgen (für die Podcast-UI). Wird von `refresh()`
    /// befüllt.
    @Published private(set) var shows: [PodcastShow] = []
    /// Ob der Server Podcast-Bibliotheken hat — steuert die Tab-Sichtbarkeit.
    /// Erst nach einem erfolgreichen `refresh()` true.
    @Published private(set) var hasPodcasts = false
    /// Server-Fortschritt je Episode (Key = `abspod:<item>:<episode>`) — Basis
    /// für die Gehört-Anzeige der ABS-Folgen (lokal gibt es dafür nichts).
    @Published private(set) var episodeProgress: [String: BookProgress] = [:]

    /// Brücke über die Original-Feed-`guid`: `abspod:`-Episoden-ID ↔ `rss:`-ID
    /// derselben Folge. So teilen sich RSS- und ABS-Kopie einer Folge eine
    /// gemeinsame Hör-History (Anzeige-Brücke + Server-Push).
    private var absToRSS: [String: String] = [:]
    private var rssToABS: [String: String] = [:]
    /// Zählt Änderungen (Shows/Fortschritt) — als `.task`-id in der UI, damit
    /// „Als Nächstes"/„Geladen" nach ABS-Laden bzw. „gehört" neu rechnen.
    @Published private(set) var changeToken = 0
    /// Archivierte Shows (client-seitig): „Abo beenden" blendet nur aus, ohne am
    /// Server zu löschen — Show + Hörhistorie bleiben erhalten, reaktivierbar.
    @Published private(set) var archivedShowIds: Set<String> = []

    /// Shows ohne archivierte (für die aktiven Sektionen).
    var activeShows: [PodcastShow] { shows.filter { !archivedShowIds.contains($0.id) } }
    /// Nur die archivierten Shows (zum Reaktivieren).
    var archivedShows: [PodcastShow] { shows.filter { archivedShowIds.contains($0.id) } }

    /// Show archivieren/reaktivieren (persistiert, KEIN Server-Eingriff).
    func setArchived(_ showId: String, _ archived: Bool) {
        if archived { archivedShowIds.insert(showId) } else { archivedShowIds.remove(showId) }
        UserDefaults.standard.set(Array(archivedShowIds), forKey: Self.archiveKey)
        changeToken += 1
    }

    // MARK: - AudioProvider

    var providerId: String { "abspod" }
    var mediaType: MediaType { .podcasts }
    var capabilities: ProviderCapabilities { [.progressSync, .downloadable] }
    var streamAuthHeaders: [String: String] { client.streamAuthHeaders }
    /// Nur wenn der Nutzer ABS ausdrücklich als Podcast-Quelle aktiviert hat.
    var isAvailable: Bool { AppStorageKeys.absPodcastsEnabledValue && hasPodcasts }

    func fetchLibraries() async throws -> [ABSLibrary] {
        try await client.fetchPodcastLibraries()
    }

    /// Bibliotheks-Items sind hier die Shows (nicht direkt abspielbar). Die
    /// Podcast-UI lädt über `refresh()`; diese Methode ist nur Vertrag.
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        try await client.fetchLibraryItems(libraryId: libraryId)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        let (showId, episodeId) = Self.split(itemId)
        guard let episodeId else { throw NSError(domain: "abspod", code: 400) }
        let detail = try await client.fetchItemDetail(itemId: showId)
        guard let episode = detail.media.episodes?.first(where: { $0.id == episodeId }) else {
            throw NSError(domain: "abspod", code: 404)
        }
        return Self.episodeDetail(itemId: itemId, show: detail, episode: episode)
    }

    func coverURL(forItemId itemId: String) -> URL? {
        client.coverURL(forItemId: Self.split(itemId).show)   // Cover der Show
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        client.streamURL(forContentPath: contentPath)
    }

    func fetchAllProgress() async throws -> [String: BookProgress] {
        try await client.fetchPodcastEpisodeProgress()
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        let (showId, episodeId) = Self.split(itemId)
        guard let episodeId else { return }
        try await client.updateEpisodeProgress(
            libraryItemId: showId, episodeId: episodeId,
            currentTime: currentTime, duration: duration, isFinished: isFinished
        )
    }

    // ABS-Podcasts nutzen keine (Buch-)Lesezeichen.
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Laden für die UI

    /// Nur prüfen, ob Podcast-Bibliotheken existieren (1 Request) — steuert die
    /// Tab-Sichtbarkeit, ohne alle Shows zu laden. Fehler/kein Login → false.
    func refreshAvailability() async {
        // ABS ist opt-in als Podcast-Quelle — ohne Aktivierung NICHT den Server
        // abfragen und Podcasts nicht als vorhanden annehmen.
        guard AppStorageKeys.absPodcastsEnabledValue else {
            if hasPodcasts { hasPodcasts = false }
            return
        }
        // NUR bei erfolgreicher Antwort aktualisieren. Ein transienter Fehler
        // (kein Netz/kurzer Hakler) darf `hasPodcasts` nicht auf false kippen —
        // sonst verschwindet der Podcast-Tab bzw. wird leer.
        guard let libs = try? await client.fetchPodcastLibraries() else { return }
        hasPodcasts = !libs.isEmpty
    }

    /// Shows + Folgen aller Podcast-Bibliotheken laden. Best effort: einzelne
    /// fehlgeschlagene Shows werden übersprungen, der Rest bleibt nutzbar.
    func refresh() async {
        // ABS ist opt-in als Podcast-Quelle — ohne Aktivierung nichts laden und
        // vorhandenen Stand leeren (der Nutzer nutzt ABS dann nur für Hörbücher).
        guard AppStorageKeys.absPodcastsEnabledValue else {
            if hasPodcasts || !shows.isEmpty { hasPodcasts = false; shows = []; changeToken += 1 }
            return
        }
        // Fehlgeschlagener Library-Fetch → bestehenden Stand BEHALTEN, nicht
        // löschen (dieser refresh läuft bei jedem Tab-Wechsel; ein kurzer
        // Netz-Hakler leerte sonst den ganzen Podcast-Tab).
        guard let libraries = try? await client.fetchPodcastLibraries() else { return }
        guard !libraries.isEmpty else {
            // Server hat wirklich keine Podcast-Bibliothek.
            hasPodcasts = false
            shows = []
            return
        }
        hasPodcasts = true
        // Fortschritt aller Episoden in einem Rutsch (für die Gehört-Anzeige).
        episodeProgress = (try? await client.fetchPodcastEpisodeProgress()) ?? episodeProgress

        // Show-Items je Library sammeln (wenige Requests).
        var itemIds: [String] = []
        for library in libraries {
            if let items = try? await client.fetchLibraryItems(libraryId: library.id) {
                itemIds.append(contentsOf: items.map(\.id))
            }
        }

        // Detail-Fetches PARALLEL, gebündelt (max ~5 gleichzeitig) — seriell war
        // bei vielen Shows spürbar langsam. Concurrency reicht (jeder Request
        // suspendiert am Netz-await), Reihenfolge egal → am Ende sortieren.
        let client = self.client
        var loaded: [PodcastShow] = []
        var newAbsToRSS: [String: String] = [:]
        var newRSSToABS: [String: String] = [:]
        var i = 0
        while i < itemIds.count {
            let batch = itemIds[i..<min(i + 5, itemIds.count)]
            i += 5
            let details = await withTaskGroup(of: LibraryItemDetail?.self) { group in
                for id in batch {
                    group.addTask { try? await client.fetchItemDetail(itemId: id) }
                }
                var out: [LibraryItemDetail] = []
                for await detail in group { if let detail { out.append(detail) } }
                return out
            }
            for detail in details {
                loaded.append(podcastShow(from: detail))
                // Brücke Feed-guid → beide IDs aufbauen (für gemeinsame History).
                let feedURL = detail.media.metadata?.feedUrl ?? ""
                guard !feedURL.isEmpty else { continue }
                let feedKey = PodcastSubscriptions.feedKey(feedURL)
                for ep in detail.media.episodes ?? [] {
                    guard let orig = ep.guid ?? ep.enclosure?.url, !orig.isEmpty else { continue }
                    let rssId = "rss:\(feedKey):\(orig)"
                    let absId = "abspod:\(detail.id):\(ep.id)"
                    newAbsToRSS[absId] = rssId
                    newRSSToABS[rssId] = absId
                }
            }
        }

        // Nur übernehmen, wenn wirklich etwas geladen wurde — sonst (alle Detail-
        // Fetches scheiterten) den bisherigen Stand behalten.
        if !loaded.isEmpty || shows.isEmpty {
            shows = loaded
            absToRSS = newAbsToRSS
            rssToABS = newRSSToABS
            changeToken += 1
        }
    }

    /// Gleichwertige IDs derselben Folge über beide Quellen (self + Brücke).
    func equivalentIds(_ id: String) -> [String] {
        if id.hasPrefix("abspod:"), let rss = absToRSS[id] { return [id, rss] }
        if id.hasPrefix("rss:"), let abs = rssToABS[id] { return [id, abs] }
        return [id]
    }

    /// Zur `rss:`-Folge die passende `abspod:`-Server-Folge (falls am Server).
    func bridgedABSId(forRSS id: String) -> String? { rssToABS[id] }

    /// Lokale (RSS-)Hör-History auf die passenden Server-Folgen pushen — nur wo
    /// der lokale Stand jünger ist als der Server. Idempotent. Nach dem Push den
    /// Server-Fortschritt neu ziehen. Greift nur für Folgen, die am Server
    /// existieren (heruntergeladen); ältere bleiben über lokal+iCloud erhalten.
    func pushLocalHistoryToServer() async {
        var didPush = false
        for (absId, rssId) in absToRSS {
            guard let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(rssId)) as? [Double],
                  arr.count == 2 else { continue }
            let localTime = arr[0], localTs = arr[1]
            let serverTs = episodeProgress[absId]?.lastUpdate ?? -1
            guard localTs > serverTs else { continue }

            let (showId, episodeId) = Self.split(absId)
            guard let episodeId,
                  let ep = shows.first(where: { $0.id == "abspod:\(showId)" })?
                      .episodes.first(where: { $0.guid == absId }) else { continue }
            let duration = ep.duration
            let isFinished = duration > 0 && localTime >= duration - 1
            try? await client.updateEpisodeProgress(
                libraryItemId: showId, episodeId: episodeId,
                currentTime: localTime, duration: duration, isFinished: isFinished
            )
            didPush = true
        }
        if didPush { await refreshProgress() }
    }

    /// Nur den Server-Fortschritt neu ziehen (nach Wiedergabe/„als gehört").
    func refreshProgress() async {
        episodeProgress = (try? await client.fetchPodcastEpisodeProgress()) ?? [:]
        changeToken += 1
    }

    // MARK: - Verwaltung (Abo anlegen / entfernen)

    /// Podcast am Server abonnieren (Feed → anlegen → neu laden). Gibt `nil`
    /// bei Erfolg zurück, sonst eine Fehlermeldung mit dem gescheiterten Schritt
    /// (damit sich blindes Raten am ungetesteten Endpoint erübrigt).
    /// - Parameter coverURL: Optionales, hochauflösendes Feed-Cover (unser
    ///   `itunes:image`). Wird nach dem Anlegen server-seitig gesetzt, weil ABS
    ///   beim Import oft das kleinere RSS-`<image>` nimmt.
    func subscribeOnServer(feedURL: String, coverURL: String? = nil,
                           autoDownload: Bool = true) async -> String? {
        do {
            guard let library = try await client.fetchPodcastLibraries().first else {
                return "Keine Podcast-Bibliothek auf dem Server."
            }
            let metadata: PodcastFeedMetadata
            do { metadata = try await client.fetchPodcastFeed(rssFeed: feedURL) }
            catch { return "Feed (podcasts/feed): \(Self.msg(error))" }

            // Ordner kommen meist schon mit dem Listen-Endpoint; sonst Detail.
            var folders = library.folders ?? []
            if folders.isEmpty {
                do { folders = try await client.fetchLibraryFolders(libraryId: library.id) }
                catch { return "Ordner (libraries/id): \(Self.msg(error))" }
            }
            guard let folder = folders.first, let folderPath = folder.fullPath else {
                return "Kein Ordner in der Podcast-Bibliothek."
            }

            let title = Self.sanitizePathComponent(metadata.title ?? "Podcast")
            let path = (folderPath as NSString).appendingPathComponent(title)
            do {
                try await client.createPodcast(libraryId: library.id, folderId: folder.id,
                                               path: path, metadata: metadata, autoDownload: autoDownload)
            } catch { return "Anlegen (POST podcasts): \(Self.msg(error))" }

            await refresh()
            // Hochauflösendes Feed-Cover nachreichen (bevorzugt unser
            // itunes:image; sonst das aus der Server-Feed-Antwort).
            await pushHighResCover(feedURL: feedURL, cover: coverURL ?? metadata.imageUrl)
            return nil
        } catch {
            return "Bibliotheken: \(Self.msg(error))"
        }
    }

    /// Cover einer bestehenden Server-Show auf ein hochauflösendes Feed-Cover
    /// heben. Best effort.
    func updateShowCover(showId: String, coverURL: String) async {
        guard showId.hasPrefix("abspod:"), !coverURL.isEmpty else { return }
        let itemId = String(showId.dropFirst("abspod:".count))
        try? await client.updateItemCover(itemId: itemId, coverURL: coverURL)
    }

    /// Das übergebene Cover auf die frisch angelegte Show anwenden (per Feed-URL
    /// wiedergefunden). Best effort — schlägt es fehl, bleibt das ABS-Cover.
    private func pushHighResCover(feedURL: String, cover: String?) async {
        guard let cover, !cover.isEmpty else { return }
        let norm = PodcastSubscriptions.normalizeFeedURL(feedURL)
        guard let show = shows.first(where: {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == norm
        }) else { return }
        let itemId = String(show.id.dropFirst("abspod:".count))
        try? await client.updateItemCover(itemId: itemId, coverURL: cover)
    }

    private static func msg(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Feed-Folgen einer ABS-Show, die noch NICHT am Server liegen (nachladbar).
    /// Abgleich über den Titel (die Library-Episoden tragen die Feed-Titel).
    func availableEpisodes(for show: PodcastShow) async -> [FeedEpisode] {
        guard !show.feedURL.isEmpty,
              let raw = try? await client.fetchFeedEpisodes(rssFeed: show.feedURL) else { return [] }
        let existing = Set(show.episodes.map { $0.title })
        return raw.compactMap { dict -> FeedEpisode? in
            let title = (dict["title"] as? String) ?? ""
            let enclosure = ((dict["enclosure"] as? [String: Any])?["url"] as? String) ?? ""
            guard !title.isEmpty, !enclosure.isEmpty, !existing.contains(title) else { return nil }
            let id = (dict["guid"] as? String) ?? enclosure
            let publishedAt = (dict["publishedAt"] as? Double)
                ?? (dict["publishedAt"] as? Int).map(Double.init) ?? 0
            let duration = (dict["duration"] as? Double)
                ?? (dict["duration"] as? Int).map(Double.init) ?? 0
            return FeedEpisode(id: id, title: title, publishedAt: publishedAt,
                               duration: duration, enclosureUrl: enclosure, raw: dict)
        }
        .sorted { $0.publishedAt < $1.publishedAt }   // älteste zuerst („von Anfang an")
    }

    /// Ausgewählte Feed-Folge server-seitig herunterladen lassen. `nil` = ok.
    func downloadEpisode(showId: String, episode: FeedEpisode) async -> String? {
        do {
            try await client.downloadEpisodes(libraryItemId: Self.split(showId).show, episodes: [episode.raw])
            return nil
        } catch {
            return Self.msg(error)
        }
    }

    /// Nach einem Server-Download: die (jetzt vorhandene) Server-Episoden-ID zu
    /// einem Feed-Titel finden. Die Server-`audioURL` ist die ABS-Pfad-URL, nicht
    /// die Origin-Enclosure → Abgleich über den Titel.
    func serverEpisodeId(showId: String, title: String) -> String? {
        shows.first { $0.id == showId }?
            .episodes.first { $0.title == title }?.guid
    }

    /// Show am Server LÖSCHEN (entfernt server-seitig alles inkl. Historie —
    /// nur für die ausdrückliche „Endgültig löschen"-Aktion, nicht fürs Archiv).
    func deleteShowOnServer(showId: String) async -> Bool {
        do {
            try await client.deleteLibraryItem(itemId: Self.split(showId).show)
            await refresh()
            return true
        } catch {
            return false
        }
    }

    /// Ungültige Pfad-Zeichen für den Server-Ordnernamen ersetzen.
    private static func sanitizePathComponent(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Podcast" : cleaned
    }

    /// Episode am Server als (un)gehört markieren und Fortschritt nachziehen.
    func setPlayed(_ item: LibraryItem, _ played: Bool) async {
        let (showId, episodeId) = Self.split(item.id)
        guard let episodeId else { return }
        let duration = item.media?.duration ?? 0
        try? await client.updateEpisodeProgress(
            libraryItemId: showId, episodeId: episodeId,
            currentTime: played ? duration : 0, duration: duration, isFinished: played
        )
        await refreshProgress()
    }

    /// Gehört-Zustand einer ABS-Episode aus dem Server-Fortschritt.
    func state(forEpisodeId itemId: String, duration: Double) -> EpisodePlayState {
        guard let bp = episodeProgress[itemId] else { return .unplayed }
        if bp.isFinished { return .played }
        if bp.fraction > 0.001 {
            let remaining = duration > 0 ? duration * (1 - bp.fraction) : 0
            return .inProgress(fraction: min(max(bp.fraction, 0), 1), remaining: remaining)
        }
        return .unplayed
    }

    /// Einzelne Episode als LibraryItem aus dem geladenen Cache (für
    /// „Weiterhören"/Wiederherstellen) — synchron, ohne Netz.
    func libraryItem(forEpisodeId itemId: String) -> LibraryItem? {
        for show in shows {
            if let episode = show.episodes.first(where: { $0.guid == itemId }) {
                return Self.libraryItem(show: show, episode: episode)
            }
        }
        return nil
    }

    // MARK: - Mapping

    /// `abspod:<showId>:<episodeId>` zerlegen. ABS-IDs enthalten keine
    /// Doppelpunkte, daher ist maxSplits 2 eindeutig.
    private static func split(_ itemId: String) -> (show: String, episode: String?) {
        let parts = itemId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "abspod" else { return (itemId, nil) }
        return (String(parts[1]), parts.count >= 3 ? String(parts[2]) : nil)
    }

    private func podcastShow(from detail: LibraryItemDetail) -> PodcastShow {
        let meta = detail.media.metadata
        let episodes = (detail.media.episodes ?? []).map { ep in
            PodcastEpisode(
                guid: "abspod:\(detail.id):\(ep.id)",
                title: ep.title ?? String(localized: "Untitled Episode"),
                audioURL: ep.audioTrack?.contentUrl ?? "",
                pubDate: ep.publishedAt ?? 0,
                duration: ep.duration ?? ep.audioTrack?.duration ?? 0,
                description: ep.description,
                imageURL: nil
            )
        }
        return PodcastShow(
            id: "abspod:\(detail.id)",
            title: meta?.title ?? "",
            author: meta?.authorName,
            // Cover läuft über coverURL(forItemId:) — hier als String mitgeben,
            // damit auch die reinen URL-Zugriffe der RSS-UI (ShowTile) greifen.
            artworkURL: client.coverURL(forItemId: detail.id)?.absoluteString,
            description: meta?.description,
            feedURL: meta?.feedUrl ?? "",
            episodes: episodes
        )
    }

    /// PodcastEpisode → LibraryItem (Track = Episoden-Audiofile).
    private static func libraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
        LibraryItem(
            id: episode.guid,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: episode.title,
                    authorName: show.title,
                    narratorName: nil,
                    seriesName: show.title,
                    genres: nil,
                    publishedYear: nil,
                    description: episode.description
                ),
                duration: episode.duration,
                chapters: nil,
                tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                       contentUrl: episode.audioURL, metadata: nil)]
            ),
            addedAt: episode.pubDate
        )
    }

    /// Server-Detail einer Show + Episode → LibraryItemDetail der Episode.
    private static func episodeDetail(itemId: String, show: LibraryItemDetail, episode: ABSPodcastEpisode) -> LibraryItemDetail {
        let track = episode.audioTrack.map {
            ABSAudioTrack(index: 0, startOffset: nil,
                          duration: episode.duration ?? $0.duration,
                          contentUrl: $0.contentUrl, metadata: $0.metadata)
        }
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title,
                authorName: show.media.metadata?.title,   // Show-Titel als „Autor"
                narratorName: nil,
                seriesName: show.media.metadata?.title,
                genres: nil,
                publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration ?? track?.duration,
            chapters: episode.chapters,   // vom Server mitgelieferte Kapitel
            tracks: track.map { [$0] }
        )
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }
}
