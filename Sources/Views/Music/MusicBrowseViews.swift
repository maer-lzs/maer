// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// Artists, variant B+C: an ENRICHED LIST. Every
/// row carries a round thumbnail (server image, else the deterministic color
/// circle with the initial), name and album count. Topped by the C row: a
/// horizontal portrait strip of ONLY artists with a real image (no color
/// circles there; it appears from ~4 images up and degrades silently).
/// Missing images resolve through the no-key chain in ArtistPortraitService
/// (server → MusicBrainz → Wikidata → Commons), lazily per visible row.
struct MusicArtistsView: View {
    @Environment(\.itemRouter) private var router
    let artists: [MusicArtist]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var query = ""
    /// C row content: artists with a RESOLVED real image (filled lazily as
    /// rows resolve; the row appears once ≥4 exist).
    @State private var portraitRow: [MusicArtist] = []

    private var shown: [MusicArtist] {
        guard !query.isEmpty else { return artists }
        return artists.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if portraitRow.count >= 4, query.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(portraitRow) { artist in
                                NavigationLink(value: MusicRoute.artist(artist)) {
                                    VStack(spacing: 4) {
                                        ArtistPortraitCircle(artist: artist, size: 72, onResolved: nil)
                                        Text(artist.name ?? "")
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .frame(width: 76)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(shown) { artist in
                    NavigationLink(value: MusicRoute.artist(artist)) {
                        HStack(spacing: 12) {
                            ArtistPortraitCircle(artist: artist, size: 44) { resolved in
                                // Feed the C row as images resolve. Only real
                                // images, first-come order, no duplicates.
                                if resolved, !portraitRow.contains(where: { $0.id == artist.id }) {
                                    portraitRow.append(artist)
                                }
                            }
                            Text(artist.name ?? String(localized: "Unknown Artist"))
                                .lineLimit(1)
                            // Both servers' artists stand side by side, not
                            // merged; the capsule tells two "Cure" apart.
                            if let source = router.sourceLabel(artist.itemId) {
                                OriginCapsule(compact: true, text: source, systemImage: nil)
                            }
                            Spacer()
                            if let count = artist.albumCount {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .barAwareList()
    }
}

/// Round artist portrait: server image or the open-source chain (lazy,
/// session-cached incl. negatives), else the deterministic color circle with
/// the initial. The artist ALWAYS appears. Plain state, no observers
/// (cell-cost convention).
struct ArtistPortraitCircle: View {
    let artist: MusicArtist
    var size: CGFloat = 44
    /// Reports whether a REAL image resolved (feeds the C row).
    var onResolved: ((Bool) -> Void)? = nil
    @State private var imageURL: URL?
    /// The flip re-runs the task (id below). Off swaps to the
    /// color circle IMMEDIATELY, no app restart.
    @AppStorage(AppStorageKeys.musicArtistImagesOnline) private var webImages = true

    var body: some View {
        ZStack {
            if let imageURL {
                CachedAsyncImage(url: imageURL, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialCircle
                }
            } else {
                initialCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(artist.itemId)-\(webImages)") {
            let info = await AppSession.shared.musicProvider(for: artist.itemId).artistInfo(artistId: artist.id)
            let resolved = await ArtistPortraitService.shared.portraitURL(
                artistKey: artist.itemId, name: artist.name,
                serverImageURL: info?.imageURL,
                musicBrainzId: info?.musicBrainzId)
            // ONE policy decides what renders (and names the source
            // in the log). The surfaces no longer each reason about it.
            let source = ArtistImagePolicy.source(serverImageURL: info?.imageURL,
                                                  webImageURL: resolved, webEnabled: webImages)
            Logger.music.notice(
                "MUSICART surface=\(size >= 64 ? "strip" : "list", privacy: .public) source=\(source.rawValue, privacy: .public) host=\(resolved?.host ?? "-", privacy: .public) webToggle=\(webImages)")
            imageURL = ArtistImagePolicy.rendered(serverImageURL: info?.imageURL,
                                                  webImageURL: resolved, webEnabled: webImages)
            onResolved?(imageURL != nil)
        }
    }

    private var initialCircle: some View {
        PlaylistArtwork.color(for: artist.id)
            .overlay(
                Text(String((artist.name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white))
    }
}

/// One artist's page: header (image + expandable bio), albums grid, top songs
/// (tap-to-play) and similar artists that exist in the OWN library. All
/// metadata sections are best-effort. Servers without agents show none.
struct MusicArtistView: View {
    let artist: MusicArtist
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var albums: [LibraryItem] = []
    @State private var loading = true
    @State private var info: MusicArtistInfo?
    @State private var topSongs: [MusicTopSong] = []
    @State private var similarInLibrary: [MusicArtist] = []
    @State private var bioExpanded = false
    /// Rank column scales with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var rankWidth: CGFloat = 22

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    CoverGrid(columns: columns) {
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
            // The artist's own server answers, whichever the device uses.
            let music = AppSession.shared.musicProvider(for: artist.itemId)
            albums = (try? await music.artistAlbums(artistId: artist.id)) ?? []
            loading = false
            info = await music.artistInfo(artistId: artist.id)
            Logger.music.notice(
                "MUSICART surface=detail source=\(info?.imageURL == nil ? "none" : "server", privacy: .public) host=\(info?.imageURL?.host ?? "-", privacy: .public)")
            topSongs = await music.topSongs(artistId: artist.id)
            // Similar artists limited to those present in the own library.
            // Foreign names without library content would dead-end.
            if let similar = info?.similarArtistNames, !similar.isEmpty {
                let libraryNames = Dictionary(
                    ((try? await music.allArtists()) ?? [])
                        .compactMap { a in a.name.map { ($0.lowercased(), a) } },
                    uniquingKeysWith: { a, _ in a })
                similarInLibrary = similar.compactMap { libraryNames[$0.lowercased()] }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let bio = strippedBio
        // The artist PAGE renders the library server's own image.
        // The open-source chain never feeds this surface (webImageURL: nil
        // states that), so the web opt-out has nothing to gate here. Routed
        // through the shared policy anyway: ONE decision, one place to change
        // should a server-image switch ever be wanted.
        let headerImage = ArtistImagePolicy.rendered(serverImageURL: info?.imageURL,
                                                     webImageURL: nil, webEnabled: false)
        if headerImage != nil || bio != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let url = headerImage {
                    // Sizing lives on the LOADED image: servers hand out image
                    // URLs even for artists without pictures. An outer frame
                    // held a 180pt hole open in that case.
                    CachedAsyncImage(url: url, useThumbnail: false) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    } placeholder: { EmptyView() }
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

    /// Server bios often carry HTML fragments/attribution links. Strip tags.
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
                // Server topSongs (global charts). Honest label.
                RowHeading.plain("Popular Songs")
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        Task { await playerCoordinator.open(item: entry.item) }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: rankWidth, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title).lineLimit(1)
                                if let album = entry.albumName {
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
                    // Top songs are queueable. The ONE shared music menu.
                    .musicItemMenu(item: entry.item, playerCoordinator: playerCoordinator)
                }
            }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similarInLibrary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.plain("Similar Artists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(similarInLibrary) { similar in
                            NavigationLink(value: MusicRoute.artist(similar)) {
                                Text(similar.name ?? String(localized: "Unknown Artist"))
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
    @Environment(\.itemRouter) private var router
    let playlists: [MusicPlaylist]
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        List(playlists) { playlist in
            NavigationLink(value: MusicRoute.album(Self.item(for: playlist))) {
                HStack {
                    Text(playlist.name ?? String(localized: "Playlist"))
                    if let source = router.sourceLabel(playlist.itemId) {
                        OriginCapsule(compact: true, text: source, systemImage: nil)
                    }
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
        .barAwareList()
    }

    /// A light library item pointing at the playlist; the detail view loads its
    /// tracks via `fetchItemDetail`.
    private static func item(for playlist: MusicPlaylist) -> LibraryItem {
        LibraryItem(
            id: playlist.itemId,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: playlist.name, authorName: nil, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil
                ),
                duration: playlist.duration,
                chapters: nil,
                tracks: nil
            ),
            addedAt: nil
        )
    }
}
