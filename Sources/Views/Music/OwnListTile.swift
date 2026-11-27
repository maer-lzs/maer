// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// An own list as a tile of a mixed row ("Listen Again"), in the row's
/// metric beside the album tiles: its mosaic as the cover, its name and
/// its number of titles below. The tile opens the list's page, as an album
/// tile opens the album; the long press offers what the list's card offers.
struct OwnListTile: View {
    let list: MaerPlaylists.Playlist
    let width: CGFloat
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.itemRouter) private var router
    @Environment(\.pushMusicRoute) private var pushMusicRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.coverGlyphKind) private var kind
    @State private var coverSide: CGFloat?

    var body: some View {
        let source = PlaylistCardSource.device(list, router: router)
        NavigationLink(value: MusicRoute.maerPlaylist(list.id)) {
            VStack(alignment: .leading, spacing: 6) {
                PlaylistArtwork(playlistID: list.id,
                                coverURLs: PlaylistCardSource.deviceCovers(list, router: router),
                                cornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { coverSide = $0 }
                    .overlay(alignment: .topTrailing) {
                        StandardCoverMarks(kind: kind, availability: nil, coverSide: coverSide)
                    }
                Text(list.name).font(.subheadline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                Text("\(source.songCount) tracks").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("listen-again-list-\(list.id)")
        .contextMenu {
            CollectionMenuItems(
                playerCoordinator: playerCoordinator, itemId: source.id,
                isPlayable: source.songCount > 0,
                play: { await source.open(playerCoordinator) },
                queueIds: { await source.shufflePool().map(\.id) },
                songs: source.shuffleDraw,
                addEntries: {
                    let songs = await source.shufflePool()
                    return (songs.map(\.id), Dictionary(songs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
                },
                details: { pushMusicRoute(source.detailRoute) })
        }
    }
}
