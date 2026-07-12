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

    /// „Als Nächstes": pro Show genau die eine Folge, mit der es weitergeht —
    /// eine laufende Folge (fortsetzen), sonst die früheste ungehörte NACH der
    /// zuletzt gehörten, sonst (nichts gehört) die älteste ungehörte. Shows, in
    /// denen alles gehört ist, entfallen. Sortiert: jüngste Folge zuerst.
    func nextUpItems() -> [LibraryItem] {
        let store = PodcastProgressStore.shared
        var picks: [(show: PodcastShow, episode: PodcastEpisode)] = []

        for show in subs.shows {
            // Chronologisch aufsteigend (alt → neu) für die „weiter"-Logik.
            // Auf Rohdaten rechnen — LibraryItem nur für die eine Auswahl bauen.
            let episodes = show.episodes.sorted { $0.pubDate < $1.pubDate }
            func state(_ ep: PodcastEpisode) -> EpisodePlayState {
                store.state(guid: ep.guid, duration: ep.duration)
            }

            // 1) Läuft gerade eine Folge? → fortsetzen (die zuletzt begonnene).
            if let running = episodes.last(where: {
                if case .inProgress = state($0) { return true } else { return false }
            }) {
                picks.append((show, running))
                continue
            }

            // 2) Nächste ungehörte nach der zuletzt gehörten, sonst älteste.
            let lastPlayed = episodes.lastIndex { state($0) == .played }
            let searchRange = lastPlayed.map { episodes.index(after: $0)..<episodes.endIndex } ?? episodes.indices
            if let next = episodes[searchRange].first(where: { state($0) == .unplayed }) {
                picks.append((show, next))
            }
        }

        return picks
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
            .map { libraryItem(show: $0.show, episode: $0.episode) }
    }

    /// Heruntergeladene Folgen (neueste zuerst) — nur Treffer werden gebaut.
    func downloadedEpisodeItems() -> [LibraryItem] {
        let ids = DownloadManager.shared.downloadedItemIds
        guard !ids.isEmpty else { return [] }
        return subs.allEpisodes()
            .filter { ids.contains($0.episode.guid) }
            .map { libraryItem(show: $0.show, episode: $0.episode) }
    }

    /// Einzelne Episode als LibraryItem über den guid-Index (O(1)) — für
    /// „Weiterhören"/Wiederherstellen, statt alle Folgen zu bauen.
    func libraryItem(forEpisodeId id: String) -> LibraryItem? {
        guard let found = subs.episode(guid: id) else { return nil }
        return libraryItem(show: found.show, episode: found.episode)
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

    /// Abgeschlossene Folgen, zuletzt gehörte zuerst, gedeckelt — Zustand direkt
    /// aus `localPosition`, LibraryItem nur für die (max. `limit`) Treffer.
    func playedEpisodeItems(limit: Int = 20) -> [LibraryItem] {
        var played: [(show: PodcastShow, episode: PodcastEpisode, updatedAt: Double)] = []
        for (show, episode) in subs.allEpisodes() {
            guard episode.duration > 0,
                  let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(episode.guid)) as? [Double],
                  stored.count == 2, stored[0] >= episode.duration - 1 else { continue }
            played.append((show, episode, stored[1]))
        }
        return played
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { libraryItem(show: $0.show, episode: $0.episode) }
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
