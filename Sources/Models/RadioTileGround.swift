// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import SwiftUI

/// 773d87b: the ground behind a logo on a radio TILE — "etwas weniger farbig",
/// deliberately not fully neutral.
///
/// A logo is a mark with its own colours; a saturated ground competes with it
/// and in the worst case collides (the red SWR3 wordmark on a lilac tile was
/// the visible case; the blue DLF wordmark on DLF-blue the reported one). The
/// ground's job is CONTRAST, not company. the owner's call keeps the hue as the
/// station identity but caps its saturation — and his "glaube ich" means the
/// final word is his, made at a before/after picture, so the cap is ONE named
/// constant he can turn.
///
/// Cards deliberately keep the old cover-colour mix (773d87b halves the scope
/// of 14f7dac): only tiles calm down.
nonisolated enum RadioTileGround {
    /// The saturation cap — the one number to turn, and it has been turned:
    /// 0.52 (old tint) → 0.13 ("etwas weniger farbig", 773d87b) → **0**
    /// (97e3a5a, the owner FINAL: tiles are a neutral white–grey–black scale;
    /// the 0.13 softening was a relay misreading of his intent, not a step he
    /// asked for). At 0 the hue term vanishes entirely — the ground carries
    /// only the counter-brightness, which is the whole point: the logo is the
    /// surface's one colour carrier. Cards keep their cover-colour mix.
    static let saturationCap: Double = 0

    /// The luminance threshold between "dark logo" and "light logo" — named
    /// because it is the second number the owner may want to move. Mid-scale.
    static let luminanceThreshold: Double = 0.5

    /// Brightness runs COUNTER to the logo, in few steps per mode — a
    /// continuous per-logo grey would make every tile subtly different, which
    /// is busier than the problem it solves.
    ///
    /// | mode  | dark logo | light logo |
    /// |-------|-----------|------------|
    /// | light | 0.93      | 0.35       |
    /// | dark  | 0.80      | 0.22       |
    static func brightness(logoLuminance: Double, darkMode: Bool) -> Double {
        let logoIsDark = logoLuminance < luminanceThreshold
        if darkMode { return logoIsDark ? 0.80 : 0.22 }
        return logoIsDark ? 0.93 : 0.35
    }

    /// Alpha-weighted mean luminance of a logo's pixels — measured, not
    /// guessed. Transparent pixels do not vote: a wordmark on a transparent
    /// PNG is mostly nothing, and counting the nothing as black would call
    /// every such logo "dark".
    static func luminance(of image: UIImage) -> Double {
        let side = 32
        guard let cg = image.cgImage else { return 0.5 }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var weighted = 0.0, alphaSum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.05 else { continue }
            // Premultiplied: un-premultiply before weighing the colour.
            let red = Double(pixels[index]) / 255 / alpha
            let green = Double(pixels[index + 1]) / 255 / alpha
            let blue = Double(pixels[index + 2]) / 255 / alpha
            weighted += (0.2126 * red + 0.7152 * green + 0.0722 * blue) * alpha
            alphaSum += alpha
        }
        guard alphaSum > 0 else { return 0.5 }
        return weighted / alphaSum
    }

    /// 804fe18 (the owner): the CARD keeps its cover HUE, but the brightness of
    /// the mix runs counter to the logo — his WDR 5 card was a dark-blue logo
    /// on a very dark ground, barely visible. Same counter rule as the tiles,
    /// on the colour scale instead of the grey scale. Few steps, no continuous
    /// math; covering brand designs (BR1 class) never reach this (they have no
    /// ground of ours).
    ///
    /// | logo   | card ground                          |
    /// |--------|--------------------------------------|
    /// | dark   | LIGHT variant of the extracted hue   |
    /// | light  | DARK variant of the extracted hue    |
    static func cardBrightness(logoLuminance: Double) -> (saturation: Double, brightness: Double) {
        let logoIsDark = logoLuminance < luminanceThreshold
        // Light variant: pastel (lower saturation so the light tone stays
        // calm); dark variant: the deep tone the cards carried anyway.
        return logoIsDark ? (saturation: 0.30, brightness: 0.88)
                          : (saturation: 0.55, brightness: 0.42)
    }

    /// Re-tone a colour to the counter-brightness while KEEPING its hue.
    static func cardTone(of color: Color, logoLuminance: Double) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let step = cardBrightness(logoLuminance: logoLuminance)
        return Color(hue: Double(hue), saturation: step.saturation, brightness: step.brightness)
    }
}
