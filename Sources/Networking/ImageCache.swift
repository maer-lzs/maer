import UIKit
import ImageIO

/// Zweistufiger Cache für Cover-Bilder: Arbeitsspeicher + Festplatte.
/// Festplatte in ZWEI Ebenen:
/// - `Caches/CoverCache`: normale Bibliothek — darf iOS bei Speicherdruck purgen.
/// - `Application Support/Covers`: Cover HERUNTERGELADENER Bücher — persistent,
///   damit das Offline-Versprechen nicht von iOS-Aufräumläufen abhängt.
///
/// Bilder werden als ORIGINAL-Bytes gespeichert (kein JPEG-Re-Encode mehr),
/// damit die volle Qualität vom Server erhalten bleibt.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL
    private let persistentDirectory: URL

    /// Größte Darstellung: Hero-Cover der Detailseite = volle Gerätebreite in
    /// Pixeln (iPhone ~1290, iPad Pro ~2064). Darüber unsichtbarer Overhead.
    /// Kurze Kante: orientierungsstabil; Deckel 2200 als Sicherheitsgrenze.
    private let maxPixelSize: CGFloat

    private init() {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        let shortSidePixels = screen.map { min($0.bounds.width, $0.bounds.height) * $0.scale } ?? 1500
        maxPixelSize = min(2200, max(1500, shortSidePixels))
        memoryCache.countLimit = 300
        // Byte-Deckel gegen Memory-Pressure durch große decodierte Cover.
        memoryCache.totalCostLimit = 150 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistentDirectory = support.appendingPathComponent("Covers", isDirectory: true)
        for dir in [diskDirectory, persistentDirectory]
        where !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Persistente Cover nicht ins Backup (können jederzeit neu geladen werden).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = persistentDirectory
        try? dir.setResourceValues(values)
    }

    /// Nur der URL-Pfad als Schlüssel — der Token in der Query würde den Key
    /// sonst bei Token-Wechsel ändern.
    private func key(for url: URL) -> String {
        url.path.replacingOccurrences(of: "/", with: "_")
    }

    /// Muss zum Pfad von `APIClient.coverURL` passen (api/items/{id}/cover).
    private func key(forItemId itemId: String) -> String {
        "_api_items_\(itemId)_cover"
    }

    /// Decoded-Bytes als NSCache-Kosten (Pixel × 4).
    private func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.width * cg.height * 4
    }

    /// Bilder > maxPixelSize hochwertig (ImageIO) verkleinern; kleinere
    /// Originale unangetastet lassen. Entlastet Disk, RAM und Scrolling.
    private func downsampled(_ data: Data) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        if max(w, h) <= maxPixelSize {
            guard let image = UIImage(data: data) else { return nil }
            return (image, data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            guard let image = UIImage(data: data) else { return nil }
            return (image, data)
        }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return (image, data) }
        return (image, jpeg)
    }

    func image(for url: URL) -> UIImage? {
        let cacheKey = key(for: url)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        for dir in [persistentDirectory, diskDirectory] {
            let fileURL = dir.appendingPathComponent(cacheKey)
            if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost(of: image))
                return image
            }
        }
        return nil
    }

    /// Speichert auf Anzeigegröße reduziert (nicht pixelig, s. maxPixelSize).
    func set(_ image: UIImage, data: Data, for url: URL) {
        let cacheKey = key(for: url)
        let stored = downsampled(data) ?? (image, data)
        memoryCache.setObject(stored.0, forKey: cacheKey as NSString, cost: cost(of: stored.0))
        try? stored.1.write(to: diskDirectory.appendingPathComponent(cacheKey))
    }

    /// Cover eines heruntergeladenen Buchs in den persistenten Ordner heben
    /// (aus dem Cache verschieben oder frisch laden).
    func makePersistent(itemId: String, coverURL: URL?) async {
        let cacheKey = key(forItemId: itemId)
        let target = persistentDirectory.appendingPathComponent(cacheKey)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let cached = diskDirectory.appendingPathComponent(cacheKey)
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.moveItem(at: cached, to: target)
            return
        }
        guard let coverURL,
              let (data, _) = try? await URLSession.shared.data(from: coverURL),
              let stored = downsampled(data) else { return }
        try? stored.1.write(to: target)
    }

    /// Beim Löschen eines Downloads: persistentes Cover zurück in den
    /// purgebaren Cache verschieben (bleibt sichtbar, ist aber aufräumbar).
    func removePersistent(itemId: String) {
        let cacheKey = key(forItemId: itemId)
        let source = persistentDirectory.appendingPathComponent(cacheKey)
        let target = diskDirectory.appendingPathComponent(cacheKey)
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.moveItem(at: source, to: target)
        } else {
            try? FileManager.default.removeItem(at: source)
        }
    }

    /// Lädt ein Cover im Hintergrund vor, falls es noch nicht im Cache ist.
    func preload(_ url: URL) async {
        guard image(for: url) == nil else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        set(image, data: data, for: url)
    }
}
