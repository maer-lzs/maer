// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension MaerPlaylists.Playlist {
    /// Where this list stands (`PlaylistHome`), with the started forms this
    /// device knows of its entries.
    var home: PlaylistHome {
        PlaylistHome.of(itemIds: itemIds, isRoutine: isRoutine) {
            ListeningStore.backup($0).flatMap(ProgressMark.markedForm)
        }
    }
}

/// The device lists of one home as the ONE name list: a row per list with a
/// small mosaic, the name and the number of titles, the most recently
/// changed first, a limited number of them and the way to all. Start,
/// Podcasts and the library draw it; only this view observes the lists.
struct PlaylistHomeSection: View {
    let home: PlaylistHome
    let playerCoordinator: PlayerCoordinator
    /// How many rows stand before the way to all; nil draws every list.
    var limit: Int? = 5
    @ObservedObject private var maerPlaylists = MaerPlaylists.shared

    var body: some View {
        let lists = PlaylistPresentation.sortedByChanged(maerPlaylists.playlists.filter { $0.home == home }) {
            Date(timeIntervalSince1970: $0.updatedAt)
        }
        if !lists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Start shows routines under their own name until a mixed
                // list joins them.
                let title: LocalizedStringKey = lists.allSatisfy(\.isRoutine) ? "Routines" : "Playlists"
                RowHeading.plain(title)
                ForEach(limit.map { Array(lists.prefix($0)) } ?? lists) { list in
                    PlaylistNameRow(list: list, playsInPlace: home == .start,
                                    playerCoordinator: playerCoordinator)
                }
                if let limit {
                    ShowAllRow(total: lists.count, hasMore: lists.count > limit,
                               destination: MusicRoute.maerPlaylists(home),
                               accessibilityId: "playlists-show-all-\(home.rawValue)")
                }
            }
        }
    }
}

/// One list in the name list. The row opens the list's page; on Start it
/// carries a button that plays the list where it stands.
struct PlaylistNameRow: View {
    let list: MaerPlaylists.Playlist
    let playsInPlace: Bool
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.itemRouter) private var router
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = 48

    var body: some View {
        let source = PlaylistCardSource.device(list, router: router)
        HStack(spacing: 12) {
            NavigationLink(value: MusicRoute.maerPlaylist(list.id)) {
                HStack(spacing: 12) {
                    PlaylistArtwork(playlistID: list.id,
                                    coverURLs: PlaylistCardSource.deviceCovers(list, router: router),
                                    cornerRadius: 6)
                        .frame(width: coverSide, height: coverSide)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text("\(source.songCount) tracks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("playlist-row-\(list.id)")
            if playsInPlace {
                Button {
                    Task { await source.open(playerCoordinator) }
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Play"))
                .accessibilityIdentifier("playlist-row-play-\(list.id)")
            }
        }
        .padding(.horizontal)
    }
}

/// Every device list of one home, the target of the name list's way to all.
struct MaerPlaylistsPage: View {
    let home: PlaylistHome
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        ScrollView {
            PlaylistHomeSection(home: home, playerCoordinator: playerCoordinator, limit: nil)
                .padding(.vertical)
        }
        .navigationTitle("Playlists")
    }
}
