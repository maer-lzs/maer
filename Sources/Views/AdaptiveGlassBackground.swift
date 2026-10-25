// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Glass look for floating elements (mini player, search button, detail
/// buttons). Uses Apple's real `.glassEffect()` (iOS 26) where available,
/// falling back to a material on older versions.
///
/// The glass carries no tint of its own: how clear or tinted it is follows
/// the system's Liquid Glass setting, the same on every glass surface.
/// `forceDark` pins the dark look of the material fallback for elements
/// living INSIDE the always-dark player/hero areas (cover gradient).

/// Glass tiering: which look a glass surface renders.
/// `.material` (DEFAULT) = the cheap translucent look, never `glassEffect`, no
/// per-frame backdrop re-sampling. `.glass` = real Liquid Glass (iOS 26). Only a
/// few hero/control surfaces (bottom bar, sort, settings) opt into `.glass`, so
/// the expensive glass runs on a handful of surfaces instead of ~20 (Apple's
/// "use glass sparingly"; glass everywhere caused the bottom-bar morph hitch).
/// `.sideColumn`: the same glass without shadow and morph, for the buttons
/// of the side column and the playback bar beside it, as the system's own
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

    private var isDark: Bool { forceDark || colorScheme == .dark }

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
                .glassEffect(.regular, in: shape)
                .glassEffectID(morphID, in: morphNamespace)
        } else {
            content
                .compositingGroup()
                .glassEffect(.regular, in: shape)
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
