// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// F5: THE playlist cover — ALWAYS a 2×2 mosaic of the first four album covers
/// (the server's single playlist cover is deliberately ignored for a uniform
/// look). Graceful degradation by available cover count: 4+ full 2×2, 3 as 2+1,
/// 2 split, 1 fills, 0 a tinted `music.note.list` glyph. Injected into the
/// poster tile via MediaTile's `coverOverride` slot.
struct PlaylistArtwork: View {
    let playlistID: String
    /// Up to four album cover URLs, in order.
    let coverURLs: [URL]

    var body: some View {
        mosaic
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var mosaic: some View {
        switch PlaylistPresentation.mosaicTileCount(coverURLs.count) {
        case 0:
            tint.overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9)))
        case 1:
            tile(coverURLs[0])
        case 2:
            HStack(spacing: 0) { tile(coverURLs[0]); tile(coverURLs[1]) }
        case 3:
            VStack(spacing: 0) {
                HStack(spacing: 0) { tile(coverURLs[0]); tile(coverURLs[1]) }
                tile(coverURLs[2])
            }
        default:
            VStack(spacing: 0) {
                HStack(spacing: 0) { tile(coverURLs[0]); tile(coverURLs[1]) }
                HStack(spacing: 0) { tile(coverURLs[2]); tile(coverURLs[3]) }
            }
        }
    }

    private func tile(_ url: URL) -> some View {
        CachedAsyncImage(url: url, useThumbnail: true) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            tint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var tint: Color { Self.color(for: playlistID) }

    /// Deterministic per-playlist tint (stable FNV-1a byte hash → hue) for the
    /// placeholder and loading tiles — like `RadioArtwork.color`.
    static func color(for id: String) -> Color {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        let hue = Double(generator.next() % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.55)
    }
}
