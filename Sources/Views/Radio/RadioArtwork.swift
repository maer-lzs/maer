// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import OSLog

/// THE radio artwork. Shared by the station rows and the big player.
/// Favicons pass a QUALITY GATE first (decoded AND shortest
/// side ≥ `RadioFaviconGate.minSide`); anything missing, broken, or tiny
/// falls back to ONE placeholder design everywhere. The deterministic
/// per-station gradient (SplitMix64, the daily-rotation RNG family) with
/// the station INITIALS (glyph when no initials derive). The HERO variant
/// (player) never upscales a low-res favicon fullscreen: the gradient
/// carries a small, sharp logo.
struct RadioArtwork: View {
    let stationID: String
    let faviconURL: URL?
    /// Station name. Feeds the placeholder initials AND the logo chain.
    var name: String = ""
    /// The station's homepage, when the caller has the station object in hand.
    /// Supplying it makes the tile independent of whether the station has been
    /// REGISTERED with the provider. The display should not inherit a
    /// precondition that something else has to create first.
    var homepage: String? = nil
    /// Hero = the big player cover; otherwise a row/tile thumbnail.
    var isHero = false
    /// Card context. The tile frame (inset + material) stays
    /// for small tiles where it serves transparent PNGs, but on a featured
    /// card the surface runs to the card's edge and sits on the CARD's own
    /// colour, so the gradient into the text zone is ONE soft transition
    /// instead of two unrelated surfaces meeting hard.
    var cardBackground: Color? = nil

    /// The surface's TARGET size in points. Small rows (search)
    /// may show a sub-64 favicon FULL, because it covers what they actually
    /// render. nil = the strict default (hero, cards, tiles): the absolute
    /// gate. One gate with a parameter, never a second one.
    var targetSide: CGFloat? = nil

    /// THE criterion: does this image cover its square surface?
    /// Near-square art fills edge-to-edge. A wordmark cannot fill a square
    /// honestly and keeps its ground. One criterion for card AND tile, so the
    /// two can never disagree about the same logo.
    static func coversItsSurface(_ image: UIImage) -> Bool {
        guard image.size.height > 0 else { return false }
        let ratio = image.size.width / image.size.height
        return (0.75...1.33).contains(ratio)
    }

    /// The share of the card artwork the colour gradient covers at the
    /// bottom (RadioFeaturedCard). The wordmark centres in what is LEFT.
    static let cardGradientShare: CGFloat = 0.3

    /// Gate result: nil until checked; .some(nil) = favicon rejected.
    @State private var gatedFavicon: UIImage??
    /// A favicon that DECODED but sits below the gate. Too small to
    /// be the tile face, honest enough for a corner badge on the placeholder.
    @State private var badgeFavicon: UIImage?

    var body: some View {
        Group {
            if isHero { hero } else { thumbnail }
        }
        // The id keys on the STATION, not the favicon URL. A
        // station without one is exactly the case that needs the chain, and
        // keying on nil made every logo-less tile share one task identity.
        .task(id: stationID) {
            // Two stages: the PREFERENCE decides who wins, not who
            // may appear first. The favicon is available NOW and paints
            // immediately; the cadenced chain upgrades the tile when it
            // arrives. Awaiting the chain before showing anything left the
            // first session on initials.
            let probe = await RadioArtwork.faviconProbe(for: faviconURL, stationID: stationID,
                                                        targetSide: targetSide)
            if let quick = probe.face {
                if gatedFavicon == nil { gatedFavicon = .some(quick) }
            } else if let small = probe.small {
                // Below the gate but decodable. The gate stays hard
                // for the SURFACE, the small image becomes a corner badge on
                // the placeholder instead of being thrown away.
                badgeFavicon = small
            }
            let preferred = await RadioArtwork.chainImage(stationID: stationID,
                                                           name: name, homepage: homepage)
            if let preferred {
                gatedFavicon = .some(preferred)
                badgeFavicon = nil   // the full image replaces the badge
            } else if gatedFavicon == nil {
                gatedFavicon = .some(nil)   // decided: placeholder (badge may stay)
            }
        }
    }

    private var tint: Color { RadioArtwork.color(for: stationID) }

    @Environment(\.colorScheme) private var colorScheme

    /// The tile's ground. Capped hue, brightness counter to the
    /// logo's measured luminance. Luminance per station is cached (a 32×32
    /// sample per redraw would be waste, and the answer never changes for a
    /// given image).
    private func tileGround(for image: UIImage) -> Color {
        let luminance = Self.cachedLuminance(stationID: stationID, image: image)
        return Color(hue: RadioArtwork.hueValue(for: stationID),
                     saturation: RadioTileGround.saturationCap,
                     brightness: RadioTileGround.brightness(
                         logoLuminance: luminance,
                         darkMode: colorScheme == .dark))
    }

    // MainActor (project default): the tile ground is only computed on the
    // render path, so the cache needs no cross-actor story.
    private static let luminanceCache = NSCache<NSString, NSNumber>()

    private static func cachedLuminance(stationID: String, image: UIImage) -> Double {
        if let cached = luminanceCache.object(forKey: stationID as NSString) {
            return cached.doubleValue
        }
        let value = RadioTileGround.luminance(of: image)
        luminanceCache.setObject(NSNumber(value: value), forKey: stationID as NSString)
        return value
    }

    /// Load order per the user's decision: **Wikidata P154 is the PRIMARY
    /// source on every surface**, the station favicon (and the chain's touch
    /// icon) are the fallback. Measured on the case that decided it: the
    /// DLF-Kultur favicon is a ~1.8 KB wordmark and answers unreliably, the
    /// P154 delivery is a vector render (960×110, crisp at every tile size).
    /// The pixel gate cannot see legibility, so the source ORDER carries it.
    /// The gate itself, the caches and the polite cadence stay mandatory and
    /// unchanged; every call site (tiles, hero, lock screen/CarPlay) inherits
    /// the order from this ONE resolver.
    static func gatedImage(for url: URL?, stationID: String) async -> UIImage? {
        // One-shot form (set-once surfaces): preference order, full await.
        if let preferred = await chainImage(stationID: stationID) { return preferred }
        return await faviconImage(for: url, stationID: stationID)
    }

    /// Stage 1. The catalog favicon, gated: available immediately.
    static func faviconImage(for url: URL?, stationID: String) async -> UIImage? {
        await faviconProbe(for: url, stationID: stationID).face
    }

    /// The probe keeps what the gate rejects: `face` passed the gate, `small`
    /// decoded but is below it. Badge material, never a tile face.
    static func faviconProbe(for url: URL?, stationID: String,
                             targetSide: CGFloat? = nil) async -> (face: UIImage?, small: UIImage?) {
        if let url, let loaded = await Artwork.loaded(for: url) {
            let image = loaded.image
            // The gate judges the picture that ARRIVED, not the thumbnail we
            // derived from it. A wide wordmark loses its short side twice
            // otherwise, once by the render and once by the downscale.
            let width = Int(loaded.sourcePixels.width)
            let height = Int(loaded.sourcePixels.height)
            if RadioFaviconGate.acceptable(pixelWidth: width, pixelHeight: height,
                                           targetSide: targetSide) {
                return (image, nil)
            }
            Logger.library.notice("RADIO favicon rejected (\(width)×\(height)): \(stationID, privacy: .public)")
            return (nil, image)
        } else if url != nil {
            Logger.library.notice("RADIO favicon could not be fetched: \(stationID, privacy: .public)")
            // The same verdict the chain's picture gets: a stored address
            // that does not serve is re-decided after two failures, and
            // the chain runs again. Only with network up; offline says
            // nothing about an address.
            if NetworkMonitor.shared.isConnected {
                await RadioLogoService.shared.noteDisplayFailure(stationID: stationID)
            }
        }
        return (nil, nil)
    }

    /// Stage 2. The preferred source (P154 first, first-party touch icon
    /// behind it), gated; cadenced, so it may take its time.
    /// `name`/`homepage` come from the caller where it holds the station; the
    /// provider lookup stays only as the fallback for the two surfaces that
    /// genuinely have no station object (player, drive mode). And there the
    /// station is registered by definition, because it is playing.
    static func chainImage(stationID: String, name: String = "",
                           homepage: String? = nil) async -> UIImage? {
        var stationName = name
        var stationHomepage = homepage
        if stationName.isEmpty {
            guard let station = RadioProvider.shared.station(forId: stationID) else {
                // Kept as diagnosis: a line here means a tile gave up before it
                // started, and it never retries. Its task is keyed on the
                // station id, which does not change.
                Logger.library.notice("RADIO chain skipped — no name and station unknown to the provider: \(stationID, privacy: .public)")
                return nil
            }
            stationName = station.name
            stationHomepage = station.homepage
        }
        guard let logoURL = await RadioLogoService.shared.logoURL(
                  stationID: stationID, name: RadioMapping.displayName(stationName),
                  homepage: stationHomepage) else { return nil }
        guard let loaded = await Artwork.loaded(for: logoURL) else {
            // A stored positive whose picture no longer serves (dead
            // frontend-version paths). The display re-opens the decision.
            // Only with network up: offline says nothing about the address.
            if NetworkMonitor.shared.isConnected {
                await RadioLogoService.shared.noteDisplayFailure(stationID: stationID)
            }
            return nil
        }
        let logo = loaded.image
        let w = Int(loaded.sourcePixels.width), h = Int(loaded.sourcePixels.height)
        // A chain result is a DECLARED logo (Commons P154 render or
        // the site's own apple-touch-icon), not a scraped favicon. It is
        // measured against the touch-icon floor. Four of the audit set's
        // misses were 57 px brand icons rejected by the favicon gate.
        guard RadioFaviconGate.acceptableTouchIcon(pixelWidth: w, pixelHeight: h) else {
            Logger.library.notice("RADIO chain logo rejected (\(w)×\(h)): \(stationID, privacy: .public)")
            // A yes from yesterday holds only for yesterday's gates.
            // An undersized STORED choice is discarded deterministically, so
            // the chain re-decides with today's gates and today's parser
            // (the 57-px stock heals itself on the next look).
            await RadioLogoService.shared.discardStored(stationID: stationID,
                                                        reason: "below today's gate \(w)x\(h)")
            return nil
        }
        RadioLogoService.clearDisplayStrikes(stationID: stationID)
        return logo
    }

    private var thumbnail: some View {
        Group {
            if let image = gatedFavicon.flatMap({ $0 }) {
                if let cardBackground {
                    // Card context: near-square art fills edge-to-edge like a
                    // music cover; a wordmark can't fill a square honestly and
                    // sits centered on the card colour instead. Either way no
                    // inner frame, the surface reaches the card's edge.
                    if Self.coversItsSurface(image) {
                        Color.clear
                            .overlay(
                                Image(uiImage: image)
                                    .resizable().aspectRatio(contentMode: .fill)
                            )
                            .clipped()
                    } else {
                        // The wordmark IS centred. But the
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
                } else if Self.coversItsSurface(image) {
                    // A logo that COVERS its surface needs no
                    // frame. The tile frame was built for transparent PNGs,
                    // and around a full-bleed logo (the DLF brand design is
                    // white bars on blue) it reads as an error. Same single
                    // criterion the card uses, not a copy of it.
                    Color.clear
                        .overlay(
                            Image(uiImage: image)
                                .resizable().aspectRatio(contentMode: .fill)
                        )
                        .clipped()
                } else {
                    // Nachtrag (1): every logo sits on a TILE surface. A
                    // transparent PNG never floats on black; the hue stays the
                    // station identity behind it.
                    //
                    // Tiles are less saturated than the logo.
                    // The saturation is CAPPED and the brightness runs
                    // counter to the measured logo luminance. A saturated
                    // ground competes with the mark (red SWR3 on lilac), and
                    // the ground's job is contrast, not company. Cards keep
                    // the old cover mix on purpose; only tiles calm down.
                    tileGround(for: image)
                        .overlay(
                            Image(uiImage: image)
                                .resizable().aspectRatio(contentMode: .fit)
                                .padding(6)
                        )
                }
            } else {
                placeholderFill
                    // The ANCHOR is decided by the component, not
                    // per call site. In a CARD the bottom edge is the soft
                    // cover→colour gradient. A badge there gets dimmed and
                    // swallowed, so the card uses the opposite corner. Plain
                    // tiles keep the family position (bottom-leading).
                    .overlay(alignment: cardBackground == nil ? .bottomLeading : .topLeading) {
                        badgeMark
                    }
            }
        }
    }

    /// The show-badge form of the episode tiles: ~24 pt, white border.
    /// Plus a small shadow, so the contrast holds on ANY ground (a card's
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
                // Small & sharp on the color field. NOT a fullscreen upscale.
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(radius: 8, y: 3)
            } else if let badge = badgeFavicon {
                // The promise of the fallback: "the gradient carries a
                // small, sharp logo". Held only for gated favicons. A
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
    /// seeds SplitMix64 (the daily-rotation RNG. Reused, not re-implemented).
    /// `String.hashValue` is per-run randomized, so the bytes are hashed
    /// explicitly for stability across launches. Fixed saturation/brightness
    /// keeps the white glyph legible.
    /// `nonisolated`. Pure, and reached from nonisolated code
    /// (the lock-screen/CarPlay placeholder renderer). Under the Swift 6
    /// language mode the inherited MainActor isolation would be an ERROR,
    /// not a warning; it is also the class of MainActor inheritance in a
    /// background context that already cost the nightly refresh once.
    nonisolated static func color(for id: String) -> Color {
        Color(hue: hue(for: id), saturation: 0.52, brightness: 0.58)
    }

    /// The station's identity hue. Shared by placeholder and tile ground.
    nonisolated static func hueValue(for id: String) -> Double { hue(for: id) }

    nonisolated private static func hue(for id: String) -> Double {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        var generator = RediscoverSections.SplitMix64(seed: seed)
        return Double(generator.next() % 360) / 360.0
    }

    /// The SAME placeholder design rendered as a UIImage for
    /// the lock screen / CarPlay now-playing artwork. One look everywhere.
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
