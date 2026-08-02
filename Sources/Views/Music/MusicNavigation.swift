// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// X15: value-based navigation for the music area — the exact pattern the
/// podcast area uses (see PodcastNavigation). Pushes go through the library's
/// `navigationPath`, so a media-tab tap (which empties that path) pops music
/// sub-pages back to the library root. Music was the last tab still using plain
/// `NavigationLink { destination }` pushes, which are NOT in the path and stayed
/// put — so from an album/artist page the tab bar could not switch library.
///
/// `Hashable` is implemented by id, so the associated values (LibraryItem,
/// the payloads hash by id, so their types stay simple.
enum MusicRoute: Hashable {
    case album(LibraryItem)
    case artist(MusicArtist)
    case artists([MusicArtist])
    case playlists([MusicPlaylist])
    // Musik-Tab-Neuordnung (30.07): the tab's library list pushes whole pages.
    case albums
    case songs
    case downloaded
    // M3: genre chip grid + one genre's albums/songs.
    case genres
    case genre(MusicGenre)
    /// 50f4751: the SEPARATE free-classical catalog area (never mixed into
    /// the personal library surfaces).
    case freeClassical

    static func == (lhs: MusicRoute, rhs: MusicRoute) -> Bool {
        switch (lhs, rhs) {
        case let (.album(a), .album(b)):         return a.id == b.id
        case let (.artist(a), .artist(b)):       return a.id == b.id
        case let (.artists(a), .artists(b)):     return a.map(\.id) == b.map(\.id)
        case let (.playlists(a), .playlists(b)): return a.map(\.id) == b.map(\.id)
        case (.albums, .albums), (.songs, .songs), (.downloaded, .downloaded),
             (.genres, .genres), (.freeClassical, .freeClassical):
            return true
        case let (.genre(a), .genre(b)):         return a.name == b.name
        default:                                 return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .album(let i):     hasher.combine(0); hasher.combine(i.id)
        case .artist(let a):    hasher.combine(1); hasher.combine(a.id)
        case .artists(let a):   hasher.combine(2); hasher.combine(a.map(\.id))
        case .playlists(let p): hasher.combine(3); hasher.combine(p.map(\.id))
        case .albums:           hasher.combine(4)
        case .songs:            hasher.combine(5)
        case .downloaded:       hasher.combine(6)
        case .genres:           hasher.combine(7)
        case .genre(let g):     hasher.combine(8); hasher.combine(g.name)
        case .freeClassical:    hasher.combine(9)
        }
    }

    /// Locale-independent handle for the UI-test harness (the visible labels are
    /// localized, e.g. "Künstler").
    var accessibilityId: String {
        switch self {
        case .album:     return "music-route-album"
        case .artist:    return "music-route-artist"
        case .artists:   return "music-route-artists"
        case .playlists: return "music-route-playlists"
        case .albums:     return "music-route-albums"
        case .songs:      return "music-route-songs"
        case .downloaded: return "music-route-downloaded"
        case .genres:     return "music-route-genres"
        case .genre:      return "music-route-genre"
        case .freeClassical: return "music-route-free-classical"
        }
    }
}

/// F5: push callback for a music route from a button-based tile (MediaTile uses
/// an onTap closure, not a NavigationLink) — set on the NavigationStack itself
/// by LibraryView, like `pushPodcastRoute`, so pushed views inherit it.
nonisolated struct PushMusicRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (MusicRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushMusicRoute: @MainActor (MusicRoute) -> Void {
        get { self[PushMusicRouteKey.self] }
        set { self[PushMusicRouteKey.self] = newValue }
    }
}

/// F5: a light library item pointing at a playlist (the detail view loads its
/// tracks via `fetchItemDetail`). Shared by the playlist list and the card row.
@MainActor
func playlistLibraryItem(_ playlist: MusicPlaylist) -> LibraryItem {
    LibraryItem(
        id: AppSession.shared.musicProvider.itemId(playlistId: playlist.id),
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: playlist.name, authorName: nil, narratorName: nil,
                seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: playlist.duration, chapters: nil, tracks: nil),
        addedAt: nil)
}

extension View {
    /// Registers the music destinations on the enclosing NavigationStack. Attach
    /// once on the stack ROOT (LibraryView), like the podcast destinations — the
    /// Home tab shows music tiles too, so the registration must always be present.
    func musicNavigationDestinations(playerCoordinator: PlayerCoordinator) -> some View {
        navigationDestination(for: MusicRoute.self) { route in
            switch route {
            case .album(let item):
                MusicAlbumView(item: item, playerCoordinator: playerCoordinator)
            case .artist(let artist):
                MusicArtistView(artist: artist, playerCoordinator: playerCoordinator)
            case .artists(let artists):
                MusicArtistsView(artists: artists, playerCoordinator: playerCoordinator)
            case .playlists(let playlists):
                MusicPlaylistsView(playlists: playlists, playerCoordinator: playerCoordinator)
            case .albums:
                MusicAlbumsPage(playerCoordinator: playerCoordinator)
            case .songs:
                MusicSongsPage(playerCoordinator: playerCoordinator)
            case .downloaded:
                MusicDownloadedPage(playerCoordinator: playerCoordinator)
            case .genres:
                MusicGenresPage()
            case .genre(let genre):
                MusicGenreDetailPage(genre: genre, playerCoordinator: playerCoordinator)
            case .freeClassical:
                FreeClassicalPage(playerCoordinator: playerCoordinator)
            }
        }
    }
}
