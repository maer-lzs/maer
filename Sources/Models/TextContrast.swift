// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The contrast of white text on a colour, by the WCAG formula, and the
/// colour darkened in its own tone until white text reads on it.
nonisolated enum TextContrast {
    /// The contrast white text needs on a colour (WCAG AA, normal text).
    static let readable = 4.5

    /// The relative luminance of an sRGB colour (components 0…1).
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast of white against a colour.
    static func againstWhite(red: Double, green: Double, blue: Double) -> Double {
        1.05 / (luminance(red: red, green: green, blue: blue) + 0.05)
    }

    /// RGBA darkened by one factor on all three channels, so the tone stays,
    /// until white text reaches `readable`; a colour that already reaches it
    /// comes back unchanged. Any other count than four comes back as given.
    static func darkenedForWhite(_ rgba: [Double]) -> [Double] {
        guard rgba.count == 4 else { return rgba }
        let (r, g, b) = (rgba[0], rgba[1], rgba[2])
        guard againstWhite(red: r, green: g, blue: b) < readable else { return rgba }
        // The contrast grows as the factor falls; the largest factor that
        // reaches it keeps the colour as light as it may be.
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if againstWhite(red: r * mid, green: g * mid, blue: b * mid) >= readable { low = mid } else { high = mid }
        }
        return [r * low, g * low, b * low, rgba[3]]
    }
}
