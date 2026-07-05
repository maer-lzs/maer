import UIKit

/// Zweistufiger Cache für Cover-Bilder: erst Arbeitsspeicher (schnell), dann
/// Festplatte (überlebt App-Neustarts). Der Grund, warum es ihn braucht:
/// SwiftUIs `AsyncImage` cached nichts und bricht das Laden ab, sobald eine
/// Kachel in einer Lazy-Liste kurz aus dem Bildschirm scrollt. Die
/// Festplatten-Ebene sorgt zusätzlich dafür, dass Cover auch offline (nach
/// einem kompletten App-Neustart, ganz ohne Netz) weiter angezeigt werden.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL

    private init() {
        memoryCache.countLimit = 300
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: diskDirectory.path) {
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    /// Nutzt bewusst nur den Pfad der URL (nicht die komplette Adresse) als
    /// Schlüssel — der Token in der Query landet sonst mit im Dateinamen und
    /// ändert sich, wodurch dasselbe Cover nach einem Token-Wechsel als "neu"
    /// gelten würde. Der Pfad allein identifiziert das Buch stabil.
    private func key(for url: URL) -> String {
        url.path.replacingOccurrences(of: "/", with: "_")
    }

    func image(for url: URL) -> UIImage? {
        let cacheKey = key(for: url)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        let fileURL = diskDirectory.appendingPathComponent(cacheKey)
        guard let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) else {
            return nil
        }
        memoryCache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    func set(_ image: UIImage, for url: URL) {
        let cacheKey = key(for: url)
        memoryCache.setObject(image, forKey: cacheKey as NSString)
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: diskDirectory.appendingPathComponent(cacheKey))
        }
    }

    /// Lädt ein Cover im Hintergrund vor, falls es noch nicht im Cache ist —
    /// ohne das Ergebnis zurückzugeben. Wird beim Laden der Bibliothek für
    /// alle Bücher aufgerufen, damit Cover auch offline verfügbar sind.
    func preload(_ url: URL) async {
        guard image(for: url) == nil else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        set(image, for: url)
    }
}
