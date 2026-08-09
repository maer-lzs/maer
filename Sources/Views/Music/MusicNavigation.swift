// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    case archiveMusic(ArchiveMusicArea)
    /// 08.08. Auflage 1: „Alte Schallplatten" exists ONLY as its genre
    /// shelves — this page lists them, there is no undivided view.
    case shellacArea
    /// M1-Korrektur: ein Katalog-Titel mit MEHREREN Spuren oeffnet seine
    /// Albumseite statt sofort zu spielen (datengetrieben, nicht sammlungs-
    /// weise: Netlabels 4-79 Spuren, Klassik 1 — gemessen).
    case catalogAlbum(String)
    /// Paket 1: eine Maer-Playlist (quellenuebergreifend, auf den Geraeten).
    case maerPlaylist(String)
    /// Welle 3 (DIE REGEL): a shelf row's full page — recent/newest as a
    /// grid. ONE parameterised page; Home's "Recently Played (Music)" row
    /// targets the same .recent page (Regel 2: no duplicate surface).
    case shelfPage(MusicShelf)
    /// Welle 3: the free-music (Jamendo) full page behind Home's row.
    case freeJamendo
    /// P8: one Jamendo genre shelf (server-paged grid).
    case jamendoShelf(String)
    /// Auftrag L1: the small music-catalog page behind Start's mixed
    /// "Entdecken · Musik" row (the I2 surface, earlier) — one source row per
    /// active catalog (classical · Jamendo), each heading onto its existing
    /// page. netlabels/78rpm/LMA grow in here later.
    case freeCatalogArea

    static func == (lhs: MusicRoute, rhs: MusicRoute) -> Bool {
        switch (lhs, rhs) {
        case let (.album(a), .album(b)):         return a.id == b.id
        case let (.artist(a), .artist(b)):       return a.id == b.id
        case let (.artists(a), .artists(b)):     return a.map(\.id) == b.map(\.id)
        case let (.playlists(a), .playlists(b)): return a.map(\.id) == b.map(\.id)
        case (.albums, .albums), (.songs, .songs), (.downloaded, .downloaded),
             (.genres, .genres), (.shellacArea, .shellacArea),
             (.freeJamendo, .freeJamendo), (.freeCatalogArea, .freeCatalogArea):
            return true
        case let (.jamendoShelf(a), .jamendoShelf(b)): return a == b
        case let (.archiveMusic(a), .archiveMusic(b)): return a == b
        case let (.catalogAlbum(a), .catalogAlbum(b)): return a == b
        case let (.maerPlaylist(a), .maerPlaylist(b)): return a == b
        case let (.shelfPage(a), .shelfPage(b)): return a == b
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
        case .archiveMusic(let a): hasher.combine(9); hasher.combine(a.key)
        case .shellacArea:      hasher.combine(14)
        case .catalogAlbum(let id): hasher.combine(15); hasher.combine(id)
        case .maerPlaylist(let id): hasher.combine(16); hasher.combine(id)
        case .shelfPage(let s): hasher.combine(10); hasher.combine(String(describing: s))
        case .freeJamendo:      hasher.combine(11)
        case .freeCatalogArea:  hasher.combine(12)
        case .jamendoShelf(let k): hasher.combine(13); hasher.combine(k)
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
        case .archiveMusic(let a): return a.routeIdentifier
        case .shellacArea: return "music-route-shellac-area"
        case .catalogAlbum: return "music-route-catalog-album"
        case .maerPlaylist: return "music-route-maer-playlist"
        case .shelfPage(let s): return "music-route-shelf-\(String(describing: s))"
        case .freeJamendo: return "music-route-free-jamendo"
        case .freeCatalogArea: return "music-route-free-catalog-area"
        case .jamendoShelf: return "music-route-jamendo-shelf"
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
            case .archiveMusic(let area):
                ArchiveMusicPage(area: area, playerCoordinator: playerCoordinator)
            case .shellacArea:
                ShellacShelvesPage(playerCoordinator: playerCoordinator)
            case .maerPlaylist(let id):
                MaerPlaylistPage(playlistId: id, playerCoordinator: playerCoordinator)
            case .catalogAlbum(let id):
                ArchiveSeriesPage(itemId: id, flavor: .album,
                                  playerCoordinator: playerCoordinator)
            case .freeCatalogArea:
                MusicCatalogAreaPage(playerCoordinator: playerCoordinator)
            case .jamendoShelf(let key):
                JamendoShelfPage(shelfKey: key, playerCoordinator: playerCoordinator)
            case .shelfPage(let shelf):
                MusicShelfPage(shelf: shelf, playerCoordinator: playerCoordinator)
            case .freeJamendo:
                FreeJamendoPage(playerCoordinator: playerCoordinator)
            }
        }
    }
}
