// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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

struct AdaptiveGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    var forceDark: Bool = false
    /// Optional cover accent: washed into the LIGHT glass so the element
    /// stays distinguishable on white backgrounds. Near-white accents
    /// (mostly white covers) are clamped to a neutral gray via luminance.
    var lightAccent: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.glassAccent) private var environmentAccent

    private var isDark: Bool { forceDark || colorScheme == .dark }

    private var lightTint: Color {
        guard let accent = lightAccent ?? environmentAccent else { return Color.white.opacity(0.3) }
        return Self.lightGlassTint(from: accent)
    }

    /// Pastel wash of the accent for light glass; luminance guard: accents
    /// close to white would vanish on white — fall back to neutral gray.
    static func lightGlassTint(from accent: Color) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        if luminance > 0.72 {
            return Color(white: 0.82).opacity(0.48)
        }
        // 35% accent over white → pastel, dark text stays readable.
        // X25b: opacity 0.3 — the same value as the dark-mode tint (and the
        // accentless white above).
        func mix(_ v: CGFloat) -> CGFloat { v * 0.35 + 0.65 }
        return Color(red: mix(r), green: mix(g), blue: mix(b)).opacity(0.3)
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content.glassEffect(
                    .regular.tint(isDark ? Color.black.opacity(0.3) : lightTint),
                    in: shape
                )
            } else {
                content
                    .background {
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(shape.fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)))
                    }
                    .overlay(shape.stroke(isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.1), lineWidth: 0.5))
            }
        }
        // Light mode: a soft shadow separates white-ish glass from white
        // backgrounds — the main reason the mini player got lost visually.
        .shadow(color: .black.opacity(isDark ? 0 : 0.12), radius: 10, y: 4)
        // Cross-fade tint changes (book switch loads a new cover accent
        // asynchronously) instead of popping hard to the new color.
        .animation(.easeInOut(duration: 0.4), value: lightTint)
    }
}
