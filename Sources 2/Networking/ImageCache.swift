import UIKit

/// Simpler In-Memory-Cache für Cover-Bilder. Der Grund, warum es ihn braucht:
/// SwiftUIs `AsyncImage` cached nichts und bricht das Laden ab, sobald eine
/// Kachel in einer Lazy-Liste kurz aus dem Bildschirm scrollt — kommt sie
/// zurück, wird oft neu (und manchmal erfolglos) geladen. Mit diesem Cache
/// wird ein einmal geladenes Cover für den Rest der App-Session sofort und
/// zuverlässig angezeigt, ganz ohne erneuten Netzwerk-Request.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func set(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
