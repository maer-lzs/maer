// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// 48e514e (3): card context — the tile frame (inset + material) stays
    /// for small tiles where it serves transparent PNGs, but on a featured
    /// card the surface runs to the card's edge and sits on the CARD's own
    /// colour, so the gradient into the text zone is ONE soft transition
    /// instead of two unrelated surfaces meeting hard.
    var cardBackground: Color? = nil

    /// 10eb85f: the surface's TARGET size in points — small rows (search)
    /// may show a sub-64 favicon FULL, because it covers what they actually
    /// render. nil = the strict default (hero, cards, tiles): the absolute
    /// gate. One gate with a parameter, never a second one.
    var targetSide: CGFloat? = nil

    /// The share of the card artwork the colour gradient covers at the
    /// bottom (RadioFeaturedCard) — the wordmark centres in what is LEFT.
    static let cardGradientShare: CGFloat = 0.3

    /// Gate result: nil until checked; .some(nil) = favicon rejected.
    @State private var gatedFavicon: UIImage??
    /// 7b910db: a favicon that DECODED but sits below the gate — too small to
    /// be the tile face, honest enough for a corner badge on the placeholder.
    @State private var badgeFavicon: UIImage?

    var body: some View {
        Group {
            if isHero { hero } else { thumbnail }
        }
        // bc11ed5: the id keys on the STATION, not the favicon URL — a
        // station without one is exactly the case that needs the chain, and
        // keying on nil made every logo-less tile share one task identity.
        .task(id: stationID) {
            // Two stages (266eb2d): the PREFERENCE decides who wins, not who
            // may appear first. The favicon is available NOW and paints
            // immediately; the cadenced chain upgrades the tile when it
            // arrives — awaiting the chain before showing anything left the
            // first session on initials.
            let probe = await RadioArtwork.faviconProbe(for: faviconURL, stationID: stationID,
                                                        targetSide: targetSide)
            if let quick = probe.face {
                if gatedFavicon == nil { gatedFavicon = .some(quick) }
            } else if let small = probe.small {
                // 7b910db: below the gate but decodable — the gate stays hard
                // for the SURFACE, the small image becomes a corner badge on
                // the placeholder instead of being thrown away.
                badgeFavicon = small
            }
            let preferred = await RadioArtwork.chainImage(stationID: stationID)
            if let preferred {
                gatedFavicon = .some(preferred)
                badgeFavicon = nil   // the full image replaces the badge
            } else if gatedFavicon == nil {
                gatedFavicon = .some(nil)   // decided: placeholder (badge may stay)
            }
        }
    }

    private var tint: Color { RadioArtwork.color(for: stationID) }

    /// Load order per the owner's decision: **Wikidata P154 is the PRIMARY
    /// source on every surface**, the station favicon (and the chain's touch
    /// icon) are the fallback. Measured on the case that decided it: the
    /// DLF-Kultur favicon is a ~1.8 KB wordmark and answers unreliably, the
    /// P154 delivery is a vector render (960×110, crisp at every tile size) —
    /// the pixel gate cannot see legibility, so the source ORDER carries it.
    /// The gate itself, the caches and the polite cadence stay mandatory and
    /// unchanged; every call site (tiles, hero, lock screen/CarPlay) inherits
    /// the order from this ONE resolver.
    static func gatedImage(for url: URL?, stationID: String) async -> UIImage? {
        // One-shot form (set-once surfaces): preference order, full await.
        if let preferred = await chainImage(stationID: stationID) { return preferred }
        return await faviconImage(for: url, stationID: stationID)
    }

    /// Stage 1 — the catalog favicon, gated: available immediately.
    static func faviconImage(for url: URL?, stationID: String) async -> UIImage? {
        await faviconProbe(for: url, stationID: stationID).face
    }

    /// The probe keeps what the gate rejects: `face` passed the gate, `small`
    /// decoded but is below it — badge material, never a tile face.
    static func faviconProbe(for url: URL?, stationID: String,
                             targetSide: CGFloat? = nil) async -> (face: UIImage?, small: UIImage?) {
        if let url, let image = await ImageCache.shared.thumbnail(for: url) {
            let width = Int(image.size.width * image.scale)
            let height = Int(image.size.height * image.scale)
            if RadioFaviconGate.acceptable(pixelWidth: width, pixelHeight: height,
                                           targetSide: targetSide) {
                return (image, nil)
            }
            Logger.library.notice("RADIO favicon rejected (\(width)×\(height)): \(stationID, privacy: .public)")
            return (nil, image)
        } else if url != nil {
            Logger.library.notice("RADIO favicon rejected (unloadable): \(stationID, privacy: .public)")
        }
        return (nil, nil)
    }

    /// Stage 2 — the preferred source (P154 first, first-party touch icon
    /// behind it), gated; cadenced, so it may take its time.
    static func chainImage(stationID: String) async -> UIImage? {
        guard let station = RadioProvider.shared.station(forId: stationID),
              let logoURL = await RadioLogoService.shared.logoURL(
                  stationID: stationID, name: RadioMapping.displayName(station.name),
                  homepage: station.homepage),
              let logo = await ImageCache.shared.thumbnail(for: logoURL) else { return nil }
        let w = Int(logo.size.width * logo.scale), h = Int(logo.size.height * logo.scale)
        // 8360dac: a chain result is a DECLARED logo (Commons P154 render or
        // the site's own apple-touch-icon), not a scraped favicon — it is
        // measured against the touch-icon floor. Four of the audit set's
        // misses were 57 px brand icons rejected by the favicon gate.
        guard RadioFaviconGate.acceptableTouchIcon(pixelWidth: w, pixelHeight: h) else {
            Logger.library.notice("RADIO chain logo rejected (\(w)×\(h)): \(stationID, privacy: .public)")
            return nil
        }
        return logo
    }

    private var thumbnail: some View {
        Group {
            if let image = gatedFavicon.flatMap({ $0 }) {
                if let cardBackground {
                    // Card context: near-square art fills edge-to-edge like a
                    // music cover; a wordmark can't fill a square honestly and
                    // sits centered on the card colour instead — either way no
                    // inner frame, the surface reaches the card's edge.
                    let ratio = image.size.height > 0
                        ? image.size.width / image.size.height : 1
                    if (0.75...1.33).contains(ratio) {
                        Color.clear
                            .overlay(
                                Image(uiImage: image)
                                    .resizable().aspectRatio(contentMode: .fill)
                            )
                            .clipped()
                    } else {
                        // 65243f2 (2): the wordmark IS centred — but the
                        // card's gradient covers the bottom third, so it
                        // reads as sitting high and small. It is therefore
                        // centred in the VISIBLE part and given more width
                        // (the inset was tuned for a full square).
                        cardBackground
                            .overlay(
                                GeometryReader { geo in
                                    Image(uiImage: image)
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .padding(.horizontal, 14)
                                        .frame(width: geo.size.width,
                                               height: geo.size.height * (1 - Self.cardGradientShare),
                                               alignment: .center)
                                }
                            )
                    }
                } else {
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
                }
            } else {
                placeholderFill
                    // d43a06b: the ANCHOR is decided by the component, not
                    // per call site. In a CARD the bottom edge is the soft
                    // cover→colour gradient — a badge there gets dimmed and
                    // swallowed, so the card uses the opposite corner. Plain
                    // tiles keep the family position (bottom-leading).
                    .overlay(alignment: cardBackground == nil ? .bottomLeading : .topLeading) {
                        badgeMark
                    }
            }
        }
    }

    /// The show-badge form of the episode tiles: ~24 pt, white border —
    /// plus a small shadow, so the contrast holds on ANY ground (a card's
    /// gradient included). One mark, one place that defines it.
    @ViewBuilder private var badgeMark: some View {
        if let badge = badgeFavicon {
            Image(uiImage: badge)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(5)
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
            } else if let badge = badgeFavicon {
                // 65243f2 (1): the Y58 promise — "the gradient carries a
                // small, sharp logo" — held only for gated favicons. A
                // decodable-but-small one landed in `badgeFavicon` and the
                // hero showed the bare initials, although the mini player
                // proved the image was there. Same badge material, hero size.
                Image(uiImage: badge)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1))
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
    /// a49444d: `nonisolated` — pure, and reached from nonisolated code
    /// (the lock-screen/CarPlay placeholder renderer). Under the Swift 6
    /// language mode the inherited MainActor isolation would be an ERROR,
    /// not a warning; it is also the Y32 class (MainActor inheritance in a
    /// background context) that already cost us the nightly refresh.
    nonisolated static func color(for id: String) -> Color {
        Color(hue: hue(for: id), saturation: 0.52, brightness: 0.58)
    }

    nonisolated private static func hue(for id: String) -> Double {
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
