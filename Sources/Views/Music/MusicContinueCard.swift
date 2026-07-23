// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Package 3: a playlist on the Home "Continue" row. Reuses the F5 2×2 mosaic
/// (`PlaylistArtwork`) as the cover — no new artwork path — over the title and a
/// progress bar; tapping resumes the playlist at its bookmarked position (the
/// provider hands `open` a `userMediaProgress` / the local backup covers same
/// device). Sized like the other featured continue cards.
struct MusicContinueCard: View {
    let item: LibraryItem
    let progress: BookProgress?
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var coverURLs: [URL] = []

    private static let width: CGFloat = 235
    private var rawId: String { SubsonicProvider.id(item.id, kind: "playlist") ?? item.id }

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PlaylistArtwork(playlistID: rawId, coverURLs: coverURLs)
                    .frame(width: Self.width, height: Self.width)

                Text(item.title).font(.headline).lineLimit(1)
                if let fraction = progress?.fraction, fraction > 0 {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(.accentColor)
                }
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            let ids = await SubsonicProvider.shared.playlistMosaicCoverIDs(playlistRawId: rawId)
            coverURLs = ids.compactMap { SubsonicProvider.shared.subsonicCoverURL(coverArtId: $0) }
        }
    }
}
