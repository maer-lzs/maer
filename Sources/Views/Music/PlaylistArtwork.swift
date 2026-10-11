// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE playlist cover: up to three album covers, two small squares on top
/// and one big square below (the server's single playlist cover is
/// deliberately ignored for a uniform look); a slot without a cover takes
/// the tint, and with none the big square carries the `music.note.list`
/// glyph. Built directly by `PlaylistCard` and the playlist page.
struct PlaylistArtwork: View {
    let playlistID: String
    /// The album cover URLs, in order; up to three are drawn.
    let coverURLs: [URL]
    /// The card row embeds the mosaic flush inside a larger rounded card:
    /// corner 0 there; standalone uses keep the default.
    var cornerRadius: CGFloat = 10

    var body: some View {
        // Two small squares on top (half width each) over one big square
        // (full width), one and a half widths tall. The frame below is
        // square, so the big square shows its upper half. Fewer than three
        // unique covers fill with the deterministic tint, never stretch or
        // stack. Every card in a row is exactly the same size.
        GeometryReader { geo in
            let w = geo.size.width
            let used = PlaylistPresentation.mosaicTileCount(coverURLs.count)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    slot(coverIndex: 1, used: used).frame(width: w / 2, height: w / 2)
                    slot(coverIndex: 2, used: used).frame(width: w / 2, height: w / 2)
                }
                slot(coverIndex: 0, used: used)
                    .frame(width: w, height: w)
                    .overlay {
                        if used == 0 {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
            }
        }
        // The square tile geometry of the other card rows (MediaTile family).
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Slot 0 = the big bottom square (first cover, most prominent);
    /// slots 1/2 = the small top squares (second/third cover); a slot without
    /// a unique cover renders the tint tile.
    @ViewBuilder
    private func slot(coverIndex: Int, used: Int) -> some View {
        if coverIndex < used {
            tile(coverURLs[coverIndex])
        } else {
            tint
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
    /// placeholder and loading tiles. Like `RadioArtwork.color`.
    /// Pure and stateless ⇒ `nonisolated`, the same class as
    /// its radio sibling. Nothing calls it off-main today, but a pure helper
    /// that inherits MainActor is a Swift-6 error waiting for its first
    /// background caller.
    nonisolated static func color(for id: String) -> Color {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        let hue = Double(generator.next() % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.55)
    }
}
