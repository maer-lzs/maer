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
    private var mosaicKey: String { item.id }

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PlaylistArtwork(playlistID: mosaicKey, coverURLs: coverURLs)
                    // Portrait card format (Kursänderung: 2:3 everywhere).
                    .frame(width: Self.width, height: Self.width * 1.5)

                Text(item.title).font(.headline).lineLimit(1, reservesSpace: true)
                // Jank convention: the bar slot is always laid out (hidden
                // when unstarted) so card heights don't depend on progress.
                ProgressView(value: min(max(progress?.fraction ?? 0, 0), 1))
                    .tint(.accentColor)
                    .opacity((progress?.fraction ?? 0) > 0 ? 1 : 0)
            }
            .frame(width: Self.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: item.id) {
            let music = AppSession.shared.musicProvider
            // M1: an ALBUM has one cover — skip the playlist mosaic lookup.
            if music.kind(of: item.id) == .album {
                coverURLs = [AppSession.shared.coverURL(forItemId: item.id)].compactMap { $0 }
            } else {
                let ids = await music.playlistMosaicCoverIDs(forItemId: item.id)
                coverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
            }
        }
    }
}
