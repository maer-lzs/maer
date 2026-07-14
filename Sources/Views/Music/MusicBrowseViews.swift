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

/// One artist's page: header (image + expandable bio), albums grid, top songs
/// (tap-to-play) and similar artists that exist in the OWN library (M2). All
/// metadata sections are best-effort — servers without agents show none.
struct MusicArtistView: View {
    let artist: SubsonicArtist
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var albums: [LibraryItem] = []
    @State private var loading = true
    @State private var info: SubsonicArtistInfo?
    @State private var topSongs: [(item: LibraryItem, song: SubsonicSong)] = []
    @State private var similarInLibrary: [SubsonicArtist] = []
    @State private var bioExpanded = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(albums) { album in
                            AlbumCell(item: album, playerCoordinator: playerCoordinator)
                        }
                    }
                    .padding(.horizontal)
                }
                topSongsSection
                similarSection
            }
            .padding(.vertical)
        }
        .navigationTitle(artist.name ?? String(localized: "Unknown Artist"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task(id: artist.id) {
            albums = (try? await SubsonicProvider.shared.artistAlbums(artistId: artist.id)) ?? []
            loading = false
            info = await SubsonicProvider.shared.artistInfo(artistId: artist.id)
            if let name = artist.name {
                topSongs = await SubsonicProvider.shared.topSongs(artistName: name)
            }
            // Similar artists limited to those present in the own library —
            // foreign names without library content would dead-end.
            if let similar = info?.similarArtist, !similar.isEmpty {
                let libraryNames = Dictionary(
                    ((try? await SubsonicProvider.shared.allArtists()) ?? [])
                        .compactMap { a in a.name.map { ($0.lowercased(), a) } },
                    uniquingKeysWith: { a, _ in a })
                similarInLibrary = similar.compactMap { s in
                    s.name.flatMap { libraryNames[$0.lowercased()] }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let bio = strippedBio
        if info?.largeImageUrl != nil || bio != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let urlString = info?.largeImageUrl, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url, useThumbnail: false) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.clear }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                if let bio {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(bioExpanded ? nil : 3)
                        .padding(.horizontal)
                        .onTapGesture { withAnimation { bioExpanded.toggle() } }
                }
            }
        }
    }

    /// Server bios often carry HTML fragments/attribution links — strip tags.
    private var strippedBio: String? {
        guard let raw = info?.biography, !raw.isEmpty else { return nil }
        let text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private var topSongsSection: some View {
        if !topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Songs").font(.title3).bold().padding(.horizontal)
                ForEach(Array(topSongs.enumerated()), id: \.element.item.id) { index, entry in
                    Button {
                        Task { await playerCoordinator.open(item: entry.item) }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.song.title ?? "–").lineLimit(1)
                                if let album = entry.song.album {
                                    Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similarInLibrary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Similar Artists").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(similarInLibrary) { similar in
                            NavigationLink {
                                MusicArtistView(artist: similar, playerCoordinator: playerCoordinator)
                            } label: {
                                Text(similar.name ?? "–")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
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
