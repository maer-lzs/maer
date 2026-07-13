import SwiftUI

/// Flat A–Z list of artists → the artist's albums.
struct MusicArtistsView: View {
    let artists: [SubsonicArtist]
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        List(artists) { artist in
            NavigationLink {
                MusicArtistView(artist: artist, playerCoordinator: playerCoordinator)
            } label: {
                HStack {
                    Text(artist.name ?? String(localized: "Unknown Artist"))
                    Spacer()
                    if let count = artist.albumCount {
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }
}

/// One artist's albums as a grid.
struct MusicArtistView: View {
    let artist: SubsonicArtist
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var albums: [LibraryItem] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(albums) { album in
                        AlbumCell(item: album, playerCoordinator: playerCoordinator)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(artist.name ?? String(localized: "Unknown Artist"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task(id: artist.id) {
            albums = (try? await SubsonicProvider.shared.artistAlbums(artistId: artist.id)) ?? []
            loading = false
        }
    }
}

/// List of playlists → the playlist as a playable track list (reusing the album
/// detail view via a `sub:playlist:` item).
struct MusicPlaylistsView: View {
    let playlists: [SubsonicPlaylist]
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        List(playlists) { playlist in
            NavigationLink {
                MusicAlbumView(item: Self.item(for: playlist), playerCoordinator: playerCoordinator)
            } label: {
                HStack {
                    Text(playlist.name ?? String(localized: "Playlist"))
                    Spacer()
                    if let count = playlist.songCount {
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }

    /// A light library item pointing at the playlist; the detail view loads its
    /// tracks via `fetchItemDetail`.
    private static func item(for playlist: SubsonicPlaylist) -> LibraryItem {
        LibraryItem(
            id: SubsonicProvider.itemId(playlistId: playlist.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: playlist.name, authorName: nil, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil
                ),
                duration: playlist.duration.map(Double.init),
                chapters: nil,
                tracks: nil
            ),
            addedAt: nil
        )
    }
}
