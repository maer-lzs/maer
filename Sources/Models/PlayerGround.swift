// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The full player's ground from the cover's average colour: more saturated
/// and lighter, so a dark cover still shows its tone, then darkened in that
/// tone until white text reads on it (`TextContrast.darkenedForWhite`). A
/// grey stays grey.
nonisolated enum PlayerGround {
    /// How much the saturation grows, and where it stops.
    static let saturationGain = 1.5
    static let saturationCeiling = 0.85
    /// Below this the colour counts as grey and keeps its saturation.
    static let greyBelow = 0.08
    /// The brightness a dark average is raised to before the cap for white text.
    static let brightnessFloor = 0.55

    /// RGBA in 0…1 lifted as above; any other count than four comes back as given.
    static func lifted(_ rgba: [Double]) -> [Double] {
        guard rgba.count == 4 else { return rgba }
        let (h, s, v) = hsv(rgba[0], rgba[1], rgba[2])
        let saturation = s < greyBelow ? s : min(max(s * saturationGain, s), saturationCeiling)
        let brightness = max(v, brightnessFloor)
        let (r, g, b) = rgb(h, saturation, brightness)
        return TextContrast.darkenedForWhite([r, g, b, rgba[3]])
    }

    static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), span = high - low
        var hue = 0.0
        if span > 0 {
            if high == r { hue = ((g - b) / span).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = (b - r) / span + 2 }
            else { hue = (r - g) / span + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high == 0 ? 0 : span / high, high)
    }

    static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let sector = (h * 6).truncatingRemainder(dividingBy: 6)
        let chroma = v * s
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - chroma
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
