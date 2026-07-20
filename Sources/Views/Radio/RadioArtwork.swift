// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Y58: THE radio artwork — shared by the station rows and the big player.
/// Favicon present → show it. Missing or broken → a deterministic per-station
/// color (SplitMix64, the same RNG family as the daily-rotation seed) filled
/// with a centered white `dot.radiowaves.left.and.right` (Apple's placeholder
/// pattern). The HERO variant (player) never upscales a low-res favicon
/// fullscreen: a full station-color gradient carries a small, sharp logo — or
/// the large SF symbol when there is no favicon.
struct RadioArtwork: View {
    let stationID: String
    let faviconURL: URL?
    /// Hero = the big player cover; otherwise a row/tile thumbnail.
    var isHero = false

    var body: some View {
        if isHero { hero } else { thumbnail }
    }

    private var tint: Color { RadioArtwork.color(for: stationID) }

    private var thumbnail: some View {
        Group {
            if let faviconURL {
                CachedAsyncImage(url: faviconURL, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholderFill }
            } else {
                placeholderFill
            }
        }
    }

    private var placeholderFill: some View {
        tint.overlay(
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.white)
        )
    }

    private var hero: some View {
        ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let faviconURL {
                // Small & sharp on the color field — NOT a fullscreen upscale.
                CachedAsyncImage(url: faviconURL, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { heroSymbol }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(radius: 8, y: 3)
            } else {
                heroSymbol
            }
        }
    }

    private var heroSymbol: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 84))
            .foregroundStyle(.white)
    }

    /// Deterministic per-station color: a stable FNV-1a byte hash of the id
    /// seeds SplitMix64 (the daily-rotation RNG — reused, not re-implemented).
    /// `String.hashValue` is per-run randomized, so the bytes are hashed
    /// explicitly for stability across launches. Fixed saturation/brightness
    /// keeps the white glyph legible.
    static func color(for id: String) -> Color {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        let hue = Double(generator.next() % 360) / 360.0
        return Color(hue: hue, saturation: 0.52, brightness: 0.58)
    }
}
