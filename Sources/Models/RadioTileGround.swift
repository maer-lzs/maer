// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import SwiftUI

/// The ground behind a logo on a radio TILE — "etwas weniger farbig",
/// deliberately not fully neutral.
///
/// A logo is a mark with its own colours; a saturated ground competes with it
/// and in the worst case collides (the red SWR3 wordmark on a lilac tile was
/// the visible case; the blue DLF wordmark on DLF-blue the reported one). The
/// ground's job is CONTRAST, not company. The hue stays as the station
/// identity, its saturation is capped, and the cap is ONE named constant.
///
/// Cards deliberately keep the old cover-colour mix: only tiles calm down.
nonisolated enum RadioTileGround {
    /// The saturation cap — the one number to turn. It stands at 0: tiles
    /// are a neutral white–grey–black scale. At 0 the hue term vanishes
    /// entirely — the ground carries
    /// only the counter-brightness, which is the whole point: the logo is the
    /// surface's one colour carrier. Cards keep their cover-colour mix.
    static let saturationCap: Double = 0

    /// The luminance threshold between "dark logo" and "light logo" — named
    /// because it is the second number the user may want to move. Mid-scale.
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

    /// The
    /// card ground is measured at the LOGO'S BOTTOM EDGE, not as a whole-image
    /// mean — the gradient attaches at the logo's lower edge, and a mean can
    /// never join it (bigFM: black edge onto beige mean; WDR: white onto
    /// blue). **Seamless attachment has priority over counter-brightness** —
    /// his call, and it solves the original dark-on-dark case with it, since
    /// the edge IS the contact surface. Title legibility follows the GROUND's
    /// luminance instead (white text on dark grounds, dark text on light).
    ///
    /// The strip: the lowest ~12 % of pixel rows, alpha-weighted; if the strip
    /// is fully transparent, walk up row-band by row-band to the next
    /// non-transparent zone, else neutral.
    static let edgeStripShare = 0.12

    /// One measured edge — colour, luminance AND the raw channels, because
    /// the dominance rule needs to compare pixels against it.
    struct Edge: Equatable {
        let red: Double, green: Double, blue: Double
        let luminance: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// Full tone only when the edge colour is
    /// the logo's DOMINANT colour — the share of visible pixels within
    /// `dominanceTolerance` of the edge must reach `dominanceShare`. DLF
    /// Kultur/1LIVE (edge == the mark's colour) stay full; WDR 2 (the edge
    /// catches the red bar of a blue-white mark) becomes a transition zone.
    /// Both numbers are named — the user turns them at the picture.
    static let dominanceShare = 0.40
    static let dominanceTolerance = 0.25   // Euclidean RGB distance

    static func dominance(of image: UIImage, edge: Edge) -> Double {
        let side = 32
        guard let pixels = samples(of: image, side: side) else { return 0 }
        var visible = 0, near = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.05 else { continue }
            visible += 1
            let dr = Double(pixels[i]) / 255 - edge.red
            let dg = Double(pixels[i + 1]) / 255 - edge.green
            let db = Double(pixels[i + 2]) / 255 - edge.blue
            if (dr * dr + dg * dg + db * db).squareRoot() <= dominanceTolerance { near += 1 }
        }
        guard visible > 0 else { return 0 }
        return Double(near) / Double(visible)
    }

    /// The calmed variant of the SAME tone for the accent case — the counter
    /// steps used for cards, keyed by the edge's
    /// own luminance: dark edge → light pastel, light edge → muted dark.
    static func dampened(_ edge: Edge) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: edge.red, green: edge.green, blue: edge.blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let dark = edge.luminance < luminanceThreshold
        return Color(hue: Double(hue),
                     saturation: dark ? 0.30 : 0.55,
                     brightness: dark ? 0.88 : 0.42)
    }

    /// Luminance of the dampened tone — the ink follows the SURFACE it sits
    /// on, which in the accent case is the calmed area, not the edge.
    static func dampenedLuminance(_ edge: Edge) -> Double {
        let dark = edge.luminance < luminanceThreshold
        // The two named steps, measured once: pastel ≈ light, muted ≈ dark.
        return dark ? 0.8 : 0.25
    }

    private static func samples(of image: UIImage, side: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    static func bottomEdgeColor(of image: UIImage) -> Edge? {
        let side = 32
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let band = max(1, Int(Double(side) * edgeStripShare))
        // CGContext draws bottom-up? No — with this setup row 0 is the TOP.
        // The bottom strip is the LAST rows; walk upwards band by band until
        // one carries ink.
        var start = side - band
        while start >= 0 {
            var red = 0.0, green = 0.0, blue = 0.0, alphaSum = 0.0
            for y in start..<min(start + band, side) {
                for x in 0..<side {
                    let i = (y * side + x) * 4
                    let alpha = Double(pixels[i + 3]) / 255
                    guard alpha > 0.05 else { continue }
                    red += Double(pixels[i]) / 255       // premultiplied
                    green += Double(pixels[i + 1]) / 255
                    blue += Double(pixels[i + 2]) / 255
                    alphaSum += alpha
                }
            }
            if alphaSum > 1 {
                let r = red / alphaSum, g = green / alphaSum, b = blue / alphaSum
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                return Edge(red: r, green: g, blue: b, luminance: luminance)
            }
            start -= band
        }
        return nil
    }

    /// Title ink for a given ground — measured, not guessed, both modes share
    /// the rule (the ground is absolute, not scheme-relative).
    static func titleIsLight(groundLuminance: Double) -> Bool {
        groundLuminance < luminanceThreshold
    }
}
