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
    /// Private/Premium-Feeds: Basic-Auth je Feed (aus dem `feedKey` der Item-ID).
    func streamAuthHeaders(forItemId itemId: String) -> [String: String] {
        PodcastFeedAuth.authHeader(forItemId: itemId)
    }

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
        var media = item.media ?? emptyMedia
        // Podcasting-2.0-Kapitel lazy nachladen (nur beim Öffnen der Folge).
        if let raw = found.episode.chaptersURL, let url = URL(string: raw),
           let chapters = await Self.loadChapters(url: url, duration: found.episode.duration) {
            media = LibraryItemMedia(metadata: media.metadata, duration: media.duration,
                                     chapters: chapters, tracks: media.tracks)
        }
        return LibraryItemDetail(id: item.id, media: media, userMediaProgress: nil)
    }

    // MARK: - Kapitel (Podcasting 2.0)

    private struct PC20ChapterList: Decodable { let chapters: [PC20Chapter] }
    private struct PC20Chapter: Decodable { let startTime: Double; let title: String? }

    /// Kapitel-JSON laden und in `[ABSChapter]` mappen (end = nächster Start,
    /// beim letzten die Episodendauer). Fehler → nil (Folge spielt ohne Kapitel).
    static func loadChapters(url: URL, duration: Double) async -> [ABSChapter]? {
        guard let (data, _) = try? await URLSession.maer.data(from: url),
              let list = try? JSONDecoder().decode(PC20ChapterList.self, from: data),
              !list.chapters.isEmpty else { return nil }
        let sorted = list.chapters.sorted { $0.startTime < $1.startTime }
        return sorted.enumerated().map { i, c in
            let end = i + 1 < sorted.count ? sorted[i + 1].startTime
                : (duration > 0 ? duration : c.startTime)
            return ABSChapter(id: i, start: c.startTime, end: end,
                              title: c.title ?? String(localized: "Chapter \(i + 1)"))
        }
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
