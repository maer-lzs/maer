import SwiftUI
import Combine
import UIKit

/// Loads a cover image and extracts dominant colors from it — one for the whole
/// Audible-style player background (`accent`), and two more only from the top
/// and bottom image edges (`topAccent`/`bottomAccent`) so top/bottom transitions
/// match the adjacent image area color-wise instead of a single average color
/// for the whole cover. Deliberately kept simple: the image is heavily
/// downscaled and the average color computed — plenty for a coherent gradient.
@MainActor
final class CoverColorLoader: ObservableObject {
    @Published var accent: Color = .gray
    @Published var topAccent: Color = .gray
    @Published var bottomAccent: Color = .gray

    /// Fertige Farben je Cover-URL — einmal berechnet, dann sofort wieder da.
    /// Nimmt die Farb-Arbeit aus dem Scroll heraus (Karten, die erneut
    /// erscheinen, treffen den Cache statt neu zu rechnen).
    private static var colorCache: [URL: (accent: Color, top: Color, bottom: Color)] = [:]

    func load(from url: URL?) async {
        guard let url else { return }
        await Self.prewarm(url: url)   // stellt sicher, dass die Farbe im Cache ist
        if let cached = Self.colorCache[url] {
            accent = cached.accent
            topAccent = cached.top
            bottomAccent = cached.bottom
        }
    }

    /// Precompute and cache colors for a cover URL — e.g. already when loading
    /// the list, so NOTHING happens while scrolling the cards. No-op if already
    /// cached.
    static func prewarm(url: URL?) async {
        guard let url, colorCache[url] == nil else { return }
        let image: UIImage
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            ImageCache.shared.set(img, data: data, for: url)
            image = img
        }
        // Color computation (CGContext draw) runs off-main (nonisolated async).
        if let colors = await colors(from: image) {
            colorCache[url] = colors
        }
    }

    /// nonisolated + async → runs on the cooperative pool, not on main.
    private nonisolated static func colors(from image: UIImage) async -> (accent: Color, top: Color, bottom: Color)? {
        guard let base = averageColor(of: image) else { return nil }
        let top = crop(image, toTop: 0.3).flatMap { averageColor(of: $0) } ?? base
        let bottom = crop(image, toBottom: 0.3).flatMap { averageColor(of: $0) } ?? base
        return (Color(base), Color(top), Color(bottom))
    }

    /// Crops the top/bottom image portion — deliberately via `UIImage.draw(at:)`
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
