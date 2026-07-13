import Foundation

/// AudioProvider for Subsonic-compatible music servers (Navidrome & co.). A new
/// media TYPE for Mär: music, not spoken audio. Mapping to the shared domain:
/// an ALBUM becomes one multi-track `LibraryItem` — its songs are `tracks` and
/// each song also gets a `chapter`, so the existing player treats "next chapter"
/// as "next song" without any change. Auth rides in the stream/cover URLs
/// (query params), so `streamAuthHeaders` stays empty.
@MainActor
final class SubsonicProvider: AudioProvider {
    static let shared = SubsonicProvider()
    private init() { reloadConfig() }

    private var client: SubsonicClient?

    var providerId: String { "sub" }
    var mediaType: MediaType { .music }
    /// Password login + own search; content is streamed from a server and can be
    /// downloaded for offline. No server-side progress sync (music needs none;
    /// "played" is handled via scrobble at the track level).
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    /// Only surfaces the Music tab when configured AND switched on.
    var isAvailable: Bool {
        AppStorageKeys.subsonicEnabledValue && client != nil
    }

    /// Rebuild the client from the stored settings (call after a settings change).
    func reloadConfig() {
        client = SubsonicClient(
            serverURL: AppStorageKeys.subsonicServerURLValue,
            username: AppStorageKeys.subsonicUsernameValue,
            password: AppStorageKeys.subsonicPasswordValue
        )
    }

    /// Validate server + credentials; returns a user-facing error string or nil.
    func testConnection() async -> String? {
        reloadConfig()
        guard let client else { return String(localized: "Enter server, username and password.") }
        do { try await client.ping(); return nil }
        catch { return (error as? SubsonicClient.SubsonicError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: - Library

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "sub", name: String(localized: "Music"), mediaType: "music")]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        // Alphabetical is the stable "browse all" order; the Music tab (later)
        // requests newest/frequent separately for its shelves.
        let albums = try await client.albumList2(type: "alphabeticalByName", size: 500)
        return albums.map(libraryItem(from:))
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let client, let albumId = Self.albumId(fromItemId: itemId),
              let album = try await client.album(id: albumId) else {
            throw SubsonicClient.SubsonicError.decoding
        }
        let songs = album.song ?? []
        var tracks: [ABSAudioTrack] = []
        var chapters: [ABSChapter] = []
        var offset = 0.0
        for (i, song) in songs.enumerated() {
            let dur = Double(song.duration ?? 0)
            // contentUrl = raw song id; streamURL(forContentPath:) turns it into
            // the authenticated stream URL.
            tracks.append(ABSAudioTrack(
                index: i, startOffset: offset, duration: dur,
                contentUrl: song.id, metadata: ABSFileMetadata(size: song.size)
            ))
            chapters.append(ABSChapter(
                id: i, start: offset, end: offset + dur,
                title: song.title ?? String(localized: "Track \(i + 1)")
            ))
            offset += dur
        }
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: album.name, authorName: album.artist, narratorName: nil,
                seriesName: nil, genres: album.genre.map { [$0] }, publishedYear: nil,
                description: nil
            ),
            duration: offset,
            chapters: chapters,
            tracks: tracks
        )
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }

    // MARK: - Media

    func coverURL(forItemId itemId: String) -> URL? {
        guard let client, let albumId = Self.albumId(fromItemId: itemId) else { return nil }
        return client.mediaURL("getCoverArt", ["id": albumId, "size": "600"])
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // contentPath is a Subsonic song id.
        client?.mediaURL("stream", ["id": contentPath])
    }

    // MARK: - Progress (no server sync — like local files; scrobble is separate)

    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}

    // MARK: - Bookmarks (unsupported)

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Mapping helpers

    private func libraryItem(from album: SubsonicAlbum) -> LibraryItem {
        LibraryItem(
            id: Self.itemId(albumId: album.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: album.name, authorName: album.artist, narratorName: nil,
                    seriesName: nil, genres: album.genre.map { [$0] }, publishedYear: nil,
                    description: nil
                ),
                duration: album.duration.map(Double.init),
                chapters: nil,
                tracks: nil
            ),
            addedAt: Self.parseCreated(album.created)
        )
    }

    static func itemId(albumId: String) -> String { "sub:album:\(albumId)" }

    static func albumId(fromItemId itemId: String) -> String? {
        let prefix = "sub:album:"
        guard itemId.hasPrefix(prefix) else { return nil }
        return String(itemId.dropFirst(prefix.count))
    }

    /// ISO-8601 `created` → epoch ms (matches ABS `addedAt`), for "Recently Added".
    /// Navidrome sends fractional seconds, which the default parser rejects — try
    /// both.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func parseCreated(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let date = iso8601Fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date.map { $0.timeIntervalSince1970 * 1000 }
    }
}
