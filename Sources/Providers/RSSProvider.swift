import Foundation

/// Podcast-Quelle über RSS/Atom-Feeds. Episoden werden als `LibraryItem`
/// abgebildet (ein Track = die Enclosure-URL), sodass Player, Downloads,
/// Sleep-Timer, Widget und CarPlay sie unverändert nutzen. Muster identisch
/// zu `LocalProvider`: der Core kennt weder den Feed-Store noch `rss:`-IDs
/// (außer dem Router in AppSession).
@MainActor
final class RSSProvider: AudioProvider {
    static let shared = RSSProvider()
    private let subs = PodcastSubscriptions.shared

    private init() {}

    var providerId: String { "rss" }
    var mediaType: MediaType { .podcasts }
    /// Podcast-Tab erst zeigen, wenn mindestens ein Feed abonniert ist.
    var isAvailable: Bool { subs.hasSubscriptions }
    /// Episoden lassen sich für offline herunterladen; kein Server-Sync,
    /// keine Server-Lesezeichen.
    var capabilities: ProviderCapabilities { [.downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "podcasts", name: String(localized: "Podcasts"))]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        subs.allEpisodes().map { libraryItem(show: $0.show, episode: $0.episode) }
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let found = subs.episode(guid: itemId) else {
            throw NSError(domain: "RSSProvider", code: 404)
        }
        let item = libraryItem(show: found.show, episode: found.episode)
        return LibraryItemDetail(id: item.id, media: item.media ?? emptyMedia, userMediaProgress: nil)
    }

    func coverURL(forItemId itemId: String) -> URL? {
        guard let found = subs.episode(guid: itemId) else { return nil }
        let raw = found.episode.imageURL ?? found.show.artworkURL
        return raw.flatMap { URL(string: $0) }
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // Bei Podcasts ist der contentPath bereits die vollständige Audio-URL.
        URL(string: contentPath)
    }

    // Fortschritt rein lokal (kein Server) — wie LocalProvider.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        var map: [String: BookProgress] = [:]
        for (show, episode) in subs.allEpisodes() {
            let item = libraryItem(show: show, episode: episode)
            guard let duration = item.media?.duration, duration > 0,
                  let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
                  stored.count == 2 else { continue }
            let time = stored[0]
            map[item.id] = BookProgress(
                fraction: min(max(time / duration, 0), 1),
                isFinished: time >= duration - 1,
                lastUpdate: stored[1],
                currentTime: time
            )
        }
        return map
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Für die Podcast-Ansicht (synchron)

    /// Neueste Folgen aller Abos als LibraryItems (Wiedergabe + Cover).
    func latestEpisodeItems() -> [LibraryItem] {
        subs.allEpisodes().map { libraryItem(show: $0.show, episode: $0.episode) }
    }

    /// Abonnierte Shows mit ihren Folgen (neueste zuerst) als LibraryItems.
    func showsWithEpisodes() -> [(show: PodcastShow, items: [LibraryItem])] {
        subs.shows.map { show in
            let items = show.episodes
                .sorted { $0.pubDate > $1.pubDate }
                .map { libraryItem(show: show, episode: $0) }
            return (show, items)
        }
    }

    /// „Als Nächstes": pro Show genau die eine Folge, mit der es weitergeht —
    /// eine laufende Folge (fortsetzen), sonst die früheste ungehörte NACH der
    /// zuletzt gehörten, sonst (nichts gehört) die älteste ungehörte. Shows, in
    /// denen alles gehört ist, entfallen. Sortiert: jüngste Folge zuerst.
    func nextUpItems() -> [LibraryItem] {
        let store = PodcastProgressStore.shared
        var picks: [(item: LibraryItem, date: Double)] = []

        for show in subs.shows {
            // Chronologisch aufsteigend (alt → neu) für die „weiter"-Logik.
            let episodes = show.episodes.sorted { $0.pubDate < $1.pubDate }
            let items = episodes.map { (ep: $0, item: libraryItem(show: show, episode: $0)) }

            func state(_ i: (ep: PodcastEpisode, item: LibraryItem)) -> EpisodePlayState {
                store.state(for: i.item)
            }

            // 1) Läuft gerade eine Folge? → fortsetzen (die zuletzt begonnene).
            if let running = items.last(where: {
                if case .inProgress = state($0) { return true } else { return false }
            }) {
                picks.append((running.item, running.ep.pubDate))
                continue
            }

            // 2) Nächste ungehörte nach der zuletzt gehörten, sonst älteste.
            let lastPlayed = items.lastIndex { state($0) == .played }
            let searchRange = lastPlayed.map { items.index(after: $0)..<items.endIndex } ?? items.indices
            if let next = items[searchRange].first(where: { state($0) == .unplayed }) {
                picks.append((next.item, next.ep.pubDate))
            }
        }

        return picks.sorted { $0.date > $1.date }.map { $0.item }
    }

    /// Heruntergeladene Folgen (neueste zuerst).
    func downloadedEpisodeItems() -> [LibraryItem] {
        let ids = DownloadManager.shared.downloadedItemIds
        return subs.allEpisodes()
            .map { libraryItem(show: $0.show, episode: $0.episode) }
            .filter { ids.contains($0.id) }
    }

    /// Show zu einer Episode (für Show-Badge und Show-Verlinkung).
    func show(forEpisodeId id: String) -> PodcastShow? {
        subs.episode(guid: id)?.show
    }

    /// Alle Folgen einer Show als LibraryItems (neueste zuerst) — für die
    /// Verlinkung Folgenseite → Show-Seite.
    func showItems(for show: PodcastShow) -> [LibraryItem] {
        show.episodes
            .sorted { $0.pubDate > $1.pubDate }
            .map { libraryItem(show: show, episode: $0) }
    }

    /// Abgeschlossene Folgen, zuletzt gehörte zuerst, gedeckelt.
    func playedEpisodeItems(limit: Int = 20) -> [LibraryItem] {
        var played: [(item: LibraryItem, updatedAt: Double)] = []
        for (show, episode) in subs.allEpisodes() {
            let item = libraryItem(show: show, episode: episode)
            guard let duration = item.media?.duration, duration > 0,
                  let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
                  stored.count == 2, stored[0] >= duration - 1 else { continue }
            played.append((item, stored[1]))
        }
        return played.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map { $0.item }
    }

    // MARK: - Mapping Episode → LibraryItem

    private func libraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
        LibraryItem(
            id: episode.guid,   // bereits "rss:<feed>:<guid>"
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: episode.title,
                    authorName: show.title,     // Show als „Autor" → Anzeige „Show — Folge"
                    narratorName: nil,
                    seriesName: show.title,      // gruppiert Folgen unter der Show
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

    private var emptyMedia: LibraryItemMedia {
        LibraryItemMedia(metadata: nil, duration: 0, chapters: nil, tracks: nil)
    }
}
