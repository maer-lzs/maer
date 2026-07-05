import SwiftUI
import Combine
import UIKit

/// Lädt ein Cover-Bild und extrahiert dominante Farben daraus — eine für den
/// ganzen Player-Hintergrund im Audible-Stil (`accent`), und zwei weitere nur
/// aus dem oberen bzw. unteren Bildrand (`topAccent`/`bottomAccent`), damit
/// Übergänge oben/unten farblich zum jeweils angrenzenden Bildbereich passen
/// statt zu einer einzigen Durchschnittsfarbe fürs ganze Cover. Bewusst
/// simpel gehalten: das Bild wird stark herunterskaliert und die
/// durchschnittliche Farbe berechnet — reicht für einen stimmigen Verlauf
/// völlig.
@MainActor
final class CoverColorLoader: ObservableObject {
    @Published var accent: Color = .gray
    @Published var topAccent: Color = .gray
    @Published var bottomAccent: Color = .gray

    func load(from url: URL?) async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            apply(cached)
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            ImageCache.shared.set(image, for: url)
            apply(image)
        } catch {
            // Kein Cover / kein Netz: neutraler Standard bleibt bestehen.
        }
    }

    private func apply(_ image: UIImage) {
        if let color = Self.averageColor(of: image) {
            accent = Color(color)
        }
        if let top = Self.crop(image, toTop: 0.3), let color = Self.averageColor(of: top) {
            topAccent = Color(color)
        }
        if let bottom = Self.crop(image, toBottom: 0.3), let color = Self.averageColor(of: bottom) {
            bottomAccent = Color(color)
        }
    }

    /// Schneidet den oberen/unteren Bildanteil zu — bewusst über
    /// `UIImage.draw(at:)` (UIKit-Koordinaten, eindeutig von oben nach unten)
    /// statt direkt über einen rohen `CGContext`: dessen Koordinatensystem
    /// läuft von unten nach oben, was beim gezielten Zuschneiden auf "oben"
    /// vs. "unten" leicht zu einer vertauschten (falschen) Zuordnung führen
    /// kann. Für die reine Gesamt-Durchschnittsfarbe (`accent`) war das
    /// bisher egal, weil dort über alle Pixel gleichermaßen gemittelt wird.
    private static func crop(_ image: UIImage, toTop fraction: CGFloat) -> UIImage? {
        let cropHeight = image.size.height * fraction
        return crop(image, to: CGRect(x: 0, y: 0, width: image.size.width, height: cropHeight))
    }

    private static func crop(_ image: UIImage, toBottom fraction: CGFloat) -> UIImage? {
        let cropHeight = image.size.height * fraction
        let y = image.size.height - cropHeight
        return crop(image, to: CGRect(x: 0, y: y, width: image.size.width, height: cropHeight))
    }

    private static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    private static func averageColor(of image: UIImage) -> UIColor? {
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

        // Leicht abdunkeln, damit weißer Text darauf lesbar bleibt.
        let factor = 0.7
        return UIColor(
            red: CGFloat(Double(r) / Double(count) / 255.0 * factor),
            green: CGFloat(Double(g) / Double(count) / 255.0 * factor),
            blue: CGFloat(Double(b) / Double(count) / 255.0 * factor),
            alpha: 1.0
        )
    }
}
