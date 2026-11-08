// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit

/// Loads a cover image and extracts dominant colors from it. One for the whole
/// Audible-style player background (`accent`), and two more only from the top
/// and bottom image edges (`topAccent`/`bottomAccent`) so top/bottom transitions
/// match the adjacent image area color-wise instead of a single average color
/// for the whole cover. Deliberately kept simple: the image is heavily
/// downscaled and the average color computed. Plenty for a coherent gradient.
@MainActor
final class CoverColorLoader: ObservableObject {
    @Published var accent: Color = .gray
    @Published var topAccent: Color = .gray
    @Published var bottomAccent: Color = .gray
    /// True once a real cover accent has ever been loaded (or restored
    /// from disk). Consumers use it to distinguish "accent available" from the
    /// neutral first-run state. The accent itself never resets to neutral.
    @Published private(set) var hasAccent = false

    /// UserDefaults key under which `accent` survives restarts; nil = no
    /// persistence (page-local loaders).
    private let persistenceKey: String?

    init(persistenceKey: String? = nil) {
        self.persistenceKey = persistenceKey
        if let persistenceKey,
           let stored = AppStorageKeys.array(persistenceKey) as? [Double],
           let restored = Self.color(fromComponents: stored) {
            accent = restored
            hasAccent = true
        }
    }

    /// Ready-made colors per cover URL. Computed once, then instantly available.
    /// Takes the color work out of scrolling (cards that reappear hit the cache
    /// instead of recomputing).
    /// Keyed by the cover's name (`ImageCache.fileKey`), so an address whose
    /// sign-in changes per request still hits.
    private static var colorCache: [String: (accent: Color, top: Color, bottom: Color)] = [:]

    func load(from url: URL?) async {
        guard let url else { return }
        await Self.prewarm(url: url)   // ensures the color is in the cache
        if let cached = Self.colorCache[ImageCache.fileKey(for: url)] {
            accent = cached.accent
            topAccent = cached.top
            bottomAccent = cached.bottom
            hasAccent = true
            if let persistenceKey {
                AppStorageKeys.set(Self.components(of: cached.accent), for: persistenceKey)
            }
        }
    }

    /// Pure and tested: RGBA round-trip for persisting the accent.
    nonisolated static func components(of color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    nonisolated static func color(fromComponents c: [Double]) -> Color? {
        guard c.count == 4 else { return nil }
        return Color(red: c[0], green: c[1], blue: c[2], opacity: c[3])
    }

    /// Precompute and cache colors for a cover URL. E.g. already when loading
    /// the list, so NOTHING happens while scrolling the cards. No-op if already
    /// cached.
    static func prewarm(url: URL?) async {
        guard let url else { return }
        let name = ImageCache.fileKey(for: url)
        guard colorCache[name] == nil else { return }
        // The one door: cache first, the cover lane second, cached after.
        guard let image = await Artwork.image(for: url)?.image else { return }
        // Color computation (CGContext draw) runs off-main (nonisolated async).
        if let colors = await colors(from: image) {
            colorCache[name] = colors
        }
    }

    /// `@concurrent`: runs the CGContext color extraction on the cooperative
    /// pool, not on main. NOTE: plain `nonisolated async` is NOT enough. Under
    /// the project's default MainActor isolation + NonisolatedNonsendingByDefault
    /// it would inherit the caller's (MainActor) executor; `@concurrent` is what
    /// actually moves this pixel work off the main thread.
    @concurrent private nonisolated static func colors(from image: UIImage) async -> (accent: Color, top: Color, bottom: Color)? {
        guard let base = averageColor(of: image) else { return nil }
        let top = crop(image, toTop: 0.3).flatMap { averageColor(of: $0) } ?? base
        let bottom = crop(image, toBottom: 0.3).flatMap { averageColor(of: $0) } ?? base
        return (Color(base), Color(top), Color(bottom))
    }

    /// The colour of a cover's bottom edge as RGBA, the rule of
    /// `bottomAccent`: the average of the lowest 30 percent, darkened for
    /// white text, and further in its own tone until white text reads on it
    /// (`TextContrast.darkenedForWhite`). The widget's snapshot carries it,
    /// so the widget computes nothing.
    nonisolated static func bottomComponents(of image: UIImage) -> [Double]? {
        guard let color = crop(image, toBottom: 0.3).flatMap({ averageColor(of: $0) }) ?? averageColor(of: image) else {
            return nil
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return TextContrast.darkenedForWhite([Double(r), Double(g), Double(b), Double(a)])
    }

    /// Crops the top/bottom image portion. Deliberately via `UIImage.draw(at:)`
    /// (UIKit coordinates, unambiguously top to bottom) rather than a raw
    /// `CGContext`: its coordinate system runs bottom to top, which for a
    /// targeted crop to "top" vs. "bottom" can easily lead to a swapped (wrong)
    /// mapping. For the pure overall average color (`accent`) this did not matter
    /// before, since it averages over all pixels equally.
    private nonisolated static func crop(_ image: UIImage, toTop fraction: CGFloat) -> UIImage? {
        let cropHeight = image.size.height * fraction
        return crop(image, to: CGRect(x: 0, y: 0, width: image.size.width, height: cropHeight))
    }

    private nonisolated static func crop(_ image: UIImage, toBottom fraction: CGFloat) -> UIImage? {
        let cropHeight = image.size.height * fraction
        let y = image.size.height - cropHeight
        return crop(image, to: CGRect(x: 0, y: y, width: image.size.width, height: cropHeight))
    }

    private nonisolated static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    private nonisolated static func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = 0, g = 0, b = 0, count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
            count += 1
        }
        guard count > 0 else { return nil }

        // Darken slightly so white text on it stays readable.
        let factor = 0.7
        return UIColor(
            red: CGFloat(Double(r) / Double(count) / 255.0 * factor),
            green: CGFloat(Double(g) / Double(count) / 255.0 * factor),
            blue: CGFloat(Double(b) / Double(count) / 255.0 * factor),
            alpha: 1.0
        )
    }
}
