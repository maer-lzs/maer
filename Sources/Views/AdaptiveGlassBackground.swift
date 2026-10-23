// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Glass look for floating elements (mini player, search button, detail
/// buttons). Uses Apple's real `.glassEffect()` (iOS 26) where available,
/// falling back to a material on older versions.
///
/// Adapts to the color scheme: dark mode darkens the glass so light text
/// stays readable over busy backgrounds; light mode brightens it for dark
/// text. `forceDark` pins the dark look for elements living INSIDE the
/// always-dark player/hero areas (cover gradient), independent of the
/// system scheme.
/// Cover accent shared through the environment so ALL nearby glass
/// elements (mini player, search button, pill, detail buttons) get the
/// same pastel wash without threading a parameter everywhere.
private struct GlassAccentKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var glassAccent: Color? {
        get { self[GlassAccentKey.self] }
        set { self[GlassAccentKey.self] = newValue }
    }
}

/// Glass tiering: which look a glass surface renders.
/// `.material` (DEFAULT) = the cheap translucent look, never `glassEffect`, no
/// per-frame backdrop re-sampling. `.glass` = real Liquid Glass (iOS 26). Only a
/// few hero/control surfaces (bottom bar, sort, settings) opt into `.glass`, so
/// the expensive glass runs on a handful of surfaces instead of ~20 (Apple's
/// "use glass sparingly"; glass everywhere caused the bottom-bar morph hitch).
/// `.sideColumn`: the system's glass without a cover tint, for the buttons of
/// the side column and the playback bar beside it, as the system's own
/// controls stand in that strip. Below iOS 26 the bar material.
nonisolated enum GlassTier { case material, glass, sideColumn }

extension View {
    /// Wraps a bottom-bar cluster in a `GlassEffectContainer` on iOS 26 so its
    /// `.glass` surfaces share ONE sampling region (Apple: "glass cannot sample
    /// other glass") and morph via `glassEffectID` instead of cross-fading
    /// independent glass surfaces. The shared region is what the bottom-bar
    /// morph hitch needed. `spacing: nil` = no automatic proximity-merge, so the
    /// distinct buttons stay separate. No-op below iOS 26.
    @ViewBuilder
    func bottomGlassContainer() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}

struct AdaptiveGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    /// `.glass` = real Liquid Glass (Material below iOS 26); `.material`
    /// (default) = the cheap look. Callers opt INTO glass, never out.
    var tier: GlassTier = .material
    var forceDark: Bool = false
    /// Optional cover accent: washed into the LIGHT glass so the element
    /// stays distinguishable on white backgrounds. Near-white accents
    /// (mostly white covers) are clamped to a neutral gray via luminance.
    var lightAccent: Color? = nil
    /// Native glass-morph identity (24.07). When a `.glass` surface lives inside
    /// a `GlassEffectContainer` and carries a `morphID` + `morphNamespace`, iOS 26
    /// morphs the GLASS SHAPE itself between two surfaces sharing the id (e.g. the
    /// media pill ↔ the round home button) instead of cross-fading two
    /// independent glass surfaces. The shared sampling region is what the
    /// bottom-bar morph hitch needed ("glass cannot sample other glass"). Only the
    /// glass shape morphs here; `matchedGeometryEffect` still handles position.
    var morphID: String? = nil
    var morphNamespace: Namespace.ID? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.glassAccent) private var environmentAccent

    private var isDark: Bool { forceDark || colorScheme == .dark }

    private var lightTint: Color {
        guard let accent = lightAccent ?? environmentAccent else { return Color.white.opacity(0.3) }
        return Self.lightGlassTint(from: accent)
    }

    /// Pastel wash of the accent for light glass; luminance guard: accents
    /// close to white would vanish on white. Fall back to neutral gray.
    static func lightGlassTint(from accent: Color) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance > 0.72 {
            return Color(white: 0.82).opacity(0.48)
        }
        // 35% accent over white → pastel, dark text stays readable.
        // Opacity 0.3: the same value as the dark-mode tint (and the
        // accentless white above).
        func mix(_ v: CGFloat) -> CGFloat { v * 0.35 + 0.65 }
        return Color(red: mix(r), green: mix(g), blue: mix(b)).opacity(0.3)
    }

    func body(content: Content) -> some View {
        Group {
            // Real Liquid Glass ONLY for `.glass` surfaces on iOS 26; everything
            // else (default `.material`, or older OS) gets the cheap look.
            if tier == .sideColumn {
                if #available(iOS 26.0, *) {
                    content.compositingGroup().glassEffect(.regular, in: shape)
                } else {
                    content.background(.bar, in: shape)
                }
            } else if tier == .glass, #available(iOS 26.0, *) {
                glassContent(content)
            } else {
                materialFallback(content)
            }
        }
        // Light mode: a soft shadow separates white-ish glass from white
        // backgrounds. The main reason the mini player got lost visually.
        // Hitch fix lever 2 (trace-backed): the shadow is limited to the few
        // `.glass` surfaces. On EVERY material surface it multiplied offscreen
        // passes (a shadow is an offscreen pass, and there are ~20 material
        // callers) while its visual purpose only ever was the glass bar.
        .shadow(color: .black.opacity(tier == .glass && !isDark ? 0.12 : 0), radius: 10, y: 4)
        // Hitch fix lever 3 (trace-backed): the tint cross-fade animated a GLASS
        // PARAMETER per frame (`AnimatableAttribute<…UnwrappedMaterial>` 374×
        // in a 9 s trace → per-frame backdrop re-render). Glass tint now changes
        // WITHOUT animation; on a title change the mini player stays where it
        // stands and takes the new tint at once. The cheap material fallback
        // keeps the cross-fade.
        .animation(tier == .glass ? nil : .easeInOut(duration: 0.4), value: lightTint)
    }

    /// Real Liquid Glass. When a morph id + namespace are given (bottom-bar
    /// cluster inside a `GlassEffectContainer`), tag the glass with
    /// `glassEffectID` so surfaces sharing the id morph into one another.
    @available(iOS 26.0, *)
    @ViewBuilder
    private func glassContent(_ content: Content) -> some View {
        // Hitch fix lever 1 (trace-backed): flatten the content into ONE layer
        // BEFORE the glass effect. The documented adoption fix for glitchy/
        // expensive glass rendering. Without it every subview contributes its
        // own layer to the effect's input and the morph multiplies offscreen
        // passes (measured 8 → 116+ with 256–328 ms single render frames).
        if let morphID, let morphNamespace {
            content
                .compositingGroup()
                .glassEffect(.regular.tint(isDark ? Color.black.opacity(0.3) : lightTint), in: shape)
                .glassEffectID(morphID, in: morphNamespace)
        } else {
            content
                .compositingGroup()
                .glassEffect(.regular.tint(isDark ? Color.black.opacity(0.3) : lightTint), in: shape)
        }
    }

    /// The cheap Material look. Used for `.material` surfaces and as the
    /// pre-iOS-26 fallback (translucent `ultraThinMaterial` + overlay + stroke).
    private func materialFallback(_ content: Content) -> some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)))
            }
            .overlay(shape.stroke(isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.1), lineWidth: 0.5))
    }
}
