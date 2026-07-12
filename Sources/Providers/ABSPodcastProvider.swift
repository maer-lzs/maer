import Foundation
import Combine

/// Audiobookshelf-Podcasts als eigene Quelle vom Typ `.podcasts`. Anders als
/// der Haupt-ABS-Provider (Hörbücher, rohe IDs) namespaced dieser Provider
/// seine IDs mit `abspod:<libraryItemId>:<episodeId>` — eine Episode ist die
/// abspielbare Einheit. Nutzt den geteilten `APIClient` (Netzwerk/Auth) und
/// hängt sich über `.progressSync` in die bestehende Sync-Maschinerie ein →
/// Fortschritt/Gehört pro Episode syncen server-seitig über alle Geräte.
@MainActor
final class ABSPodcastProvider: ObservableObject, AudioProvider {
    static let shared = ABSPodcastProvider()
    private init() {}

    private var client: APIClient { AppSession.shared.apiClient }

    /// Geladene Shows samt Folgen (für die Podcast-UI). Wird von `refresh()`
    /// befüllt.
    @Published private(set) var shows: [PodcastShow] = []
    /// Ob der Server Podcast-Bibliotheken hat — steuert die Tab-Sichtbarkeit.
    /// Erst nach einem erfolgreichen `refresh()` true.
    @Published private(set) var hasPodcasts = false

    // MARK: - AudioProvider

    var providerId: String { "abspod" }
    var mediaType: MediaType { .podcasts }
    var capabilities: ProviderCapabilities { [.progressSync, .downloadable] }
    var streamAuthHeaders: [String: String] { client.streamAuthHeaders }
    var isAvailable: Bool { hasPodcasts }

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
        let libs = try? await client.fetchPodcastLibraries()
        hasPodcasts = (libs?.isEmpty == false)
    }

    /// Shows + Folgen aller Podcast-Bibliotheken laden. Best effort: einzelne
    /// fehlgeschlagene Shows werden übersprungen, der Rest bleibt nutzbar.
    func refresh() async {
        guard let libraries = try? await client.fetchPodcastLibraries(), !libraries.isEmpty else {
            hasPodcasts = false
            shows = []
            return
        }
        hasPodcasts = true
        var loaded: [PodcastShow] = []
        for library in libraries {
            guard let items = try? await client.fetchLibraryItems(libraryId: library.id) else { continue }
            for item in items {
                guard let detail = try? await client.fetchItemDetail(itemId: item.id) else { continue }
                loaded.append(podcastShow(from: detail))
            }
        }
        shows = loaded
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
            chapters: nil,
            tracks: track.map { [$0] }
        )
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }
}
