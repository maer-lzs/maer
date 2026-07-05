import SwiftUI
import Combine
import UIKit

/// Lädt ein Cover-Bild und extrahiert eine dominante Farbe daraus, um den
/// Player-Hintergrund im Audible-Stil einzufärben. Bewusst simpel gehalten:
/// das Bild wird stark herunterskaliert und die durchschnittliche Farbe
/// berechnet — reicht für einen stimmigen Gradient völlig.
@MainActor
final class CoverColorLoader: ObservableObject {
    @Published var accent: Color = .gray

    func load(from url: URL?) async {
        guard let url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data),
                  let color = Self.averageColor(of: image) else { return }
            accent = Color(color)
        } catch {
            // Kein Cover / kein Netz: neutraler Standard bleibt bestehen.
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
