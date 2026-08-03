// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import OSLog

/// Y58: THE radio artwork — shared by the station rows and the big player.
/// cd5cc4a (1): favicons pass a QUALITY GATE first (decoded AND shortest
/// side ≥ `RadioFaviconGate.minSide`); anything missing, broken, or tiny
/// falls back to ONE placeholder design everywhere — the deterministic
/// per-station gradient (SplitMix64, the daily-rotation RNG family) with
/// the station INITIALS (glyph when no initials derive). The HERO variant
/// (player) never upscales a low-res favicon fullscreen: the gradient
/// carries a small, sharp logo.
struct RadioArtwork: View {
    let stationID: String
    let faviconURL: URL?
    /// Station name — feeds the placeholder initials.
    var name: String = ""
    /// Hero = the big player cover; otherwise a row/tile thumbnail.
    var isHero = false

    /// Gate result: nil until checked; .some(nil) = favicon rejected.
    @State private var gatedFavicon: UIImage??

    var body: some View {
        Group {
            if isHero { hero } else { thumbnail }
        }
        .task(id: faviconURL) {
            gatedFavicon = .some(await RadioArtwork.gatedImage(for: faviconURL, stationID: stationID))
        }
    }

    private var tint: Color { RadioArtwork.color(for: stationID) }

    /// Load through the shared ImageCache, then apply the pure gate.
    /// Rejections log the reason and stay silent toward the user (spec).
    static func gatedImage(for url: URL?, stationID: String) async -> UIImage? {
        guard let url else { return nil }
        guard let image = await ImageCache.shared.thumbnail(for: url) else {
            Logger.library.notice("RADIO favicon rejected (unloadable): \(stationID, privacy: .public)")
            return nil
        }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard RadioFaviconGate.acceptable(pixelWidth: width, pixelHeight: height) else {
            Logger.library.notice("RADIO favicon rejected (\(width)×\(height)): \(stationID, privacy: .public)")
            return nil
        }
        return image
    }

    private var thumbnail: some View {
        Group {
            if let image = gatedFavicon.flatMap({ $0 }) {
                // Nachtrag (1): every logo sits on a TILE surface — a
                // transparent PNG never floats on black; the deterministic
                // tint doubles as the station identity behind it.
                tint.opacity(0.35)
                    .overlay(
                        Image(uiImage: image)
                            .resizable().aspectRatio(contentMode: .fit)
                            .padding(6)
                    )
                    .background(.thinMaterial)
            } else {
                placeholderFill
            }
        }
    }

    private var placeholderFill: some View {
        LinearGradient(colors: [tint, tint.opacity(0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                GeometryReader { geo in
                    placeholderMark(side: min(geo.size.width, geo.size.height))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            )
    }

    @ViewBuilder
    private func placeholderMark(side: CGFloat) -> some View {
        if let initials = RadioFaviconGate.initials(for: name) {
            Text(initials)
                .font(.system(size: side * 0.36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: side * 0.3))
                .foregroundStyle(.white)
        }
    }

    private var hero: some View {
        ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = gatedFavicon.flatMap({ $0 }) {
                // Small & sharp on the color field — NOT a fullscreen upscale.
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(radius: 8, y: 3)
            } else {
                placeholderMark(side: 220)
            }
        }
    }

    /// Deterministic per-station color: a stable FNV-1a byte hash of the id
    /// seeds SplitMix64 (the daily-rotation RNG — reused, not re-implemented).
    /// `String.hashValue` is per-run randomized, so the bytes are hashed
    /// explicitly for stability across launches. Fixed saturation/brightness
    /// keeps the white glyph legible.
    static func color(for id: String) -> Color {
        Color(hue: hue(for: id), saturation: 0.52, brightness: 0.58)
    }

    private static func hue(for id: String) -> Double {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        return Double(generator.next() % 360) / 360.0
    }

    /// cd5cc4a (1): the SAME placeholder design rendered as a UIImage for
    /// the lock screen / CarPlay now-playing artwork — one look everywhere.
    nonisolated static func placeholderImage(stationID: String, name: String,
                                             side: CGFloat = 600) -> UIImage {
        let hue = hue(for: stationID)
        let top = UIColor(hue: hue, saturation: 0.52, brightness: 0.58, alpha: 1)
        let bottom = UIColor(hue: hue, saturation: 0.52, brightness: 0.58, alpha: 0.62)
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let text = RadioFaviconGate.initials(for: name) ?? "((·))"
            let font = UIFont.systemFont(ofSize: side * 0.36, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFontMetrics.default.scaledFont(for: font),
                .foregroundColor: UIColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2),
                withAttributes: attributes)
        }
    }
}
