import UIKit
import ImageIO

/// Two-tier cache for cover images: memory + disk. Disk in TWO tiers:
/// - `Caches/CoverCache`: normal library — iOS may purge it under memory pressure.
/// - `Application Support/Covers`: covers of DOWNLOADED books — persistent, so
///   the offline promise does not depend on iOS cleanup runs.
///
/// Images are stored as ORIGINAL bytes (no JPEG re-encode) to keep the full
/// quality from the server.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    /// Is a prefetch running for this cover? Prevents loading the same cover
    /// multiple times in parallel (prefetch + visible cell).
    private var inFlight = Set<URL>()
    /// Small tier derived from the full covers for grid/row cells: decoding
    /// the full ~2000 px cover for a ~150 pt cell costs ~16 MB RAM per image
    /// and stutters scrolling with large libraries. Memory-only — always
    /// derivable from the disk tiers.
    private let thumbCache = NSCache<NSString, UIImage>()
    private let thumbPixelSize: CGFloat = 400
    private let diskDirectory: URL
    private let persistentDirectory: URL

    /// Device-adaptive storage size (longest side): screen short side in
    /// pixels × 1.6 headroom — plain 1× turned out visibly soft on modern
    /// iPhones. Clamped to 1500 (older, low-res devices don't need more)
    /// … 2200 (above the iPad-Pro hero width is invisible overhead).
    /// Modern iPhones land at ~1900–2100, iPads at 2200.
    private let maxPixelSize: CGFloat

    private init() {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        let shortSidePixels = screen.map { min($0.bounds.width, $0.bounds.height) * $0.scale } ?? 1500
        maxPixelSize = min(2200, max(1500, shortSidePixels * 1.6))
        memoryCache.countLimit = 300
        // Byte cap against memory pressure from large decoded covers.
        memoryCache.totalCostLimit = 150 * 1024 * 1024
        thumbCache.countLimit = 600
        thumbCache.totalCostLimit = 40 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistentDirectory = support.appendingPathComponent("Covers", isDirectory: true)
        for dir in [diskDirectory, persistentDirectory]
        where !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Keep persistent covers out of backups (can be re-downloaded anytime).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = persistentDirectory
        try? dir.setResourceValues(values)
    }

    /// Auth/session query params that rotate per request and must NOT enter the
    /// cache key (Subsonic sends a fresh salt+token every call).
    private static let volatileQueryParams: Set<String> = ["t", "s", "u", "c", "v", "f", "p"]

    /// Host + path + the STABLE query params (e.g. Subsonic `id`/`size`). Path
    /// alone collided every Subsonic cover onto one key — their identifying
    /// `id` lives in the query, so all albums shared a single cached file.
    nonisolated private func key(for url: URL) -> String {
        var parts = [url.host ?? "", url.path]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let stable = items
                .filter { !Self.volatileQueryParams.contains($0.name) }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value ?? "")" }
            parts.append(contentsOf: stable)
        }
        return parts.joined(separator: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Must match the path of `APIClient.coverURL` (api/items/{id}/cover).
    private func key(forItemId itemId: String) -> String {
        "_api_items_\(itemId)_cover"
    }

    #if DEBUG
    /// Test seam for the pure key derivation.
    nonisolated func testKey(for url: URL) -> String { key(for: url) }
    #endif

    /// Decoded bytes as NSCache cost (pixels × 4).
    private func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.width * cg.height * 4
    }

    /// Downsample images > maxPixelSize at high quality (ImageIO); leave smaller
    /// originals untouched. nonisolated + static: runs on a background thread,
    /// NOT on the MainActor (ImageIO decodes of large covers would otherwise
    /// stutter the UI).
    private nonisolated static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> (UIImage, Data)? {
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

    /// Thumbnail (≤ thumbPixelSize) for grid/row cells, derived on demand
    /// from the disk tiers. Returns nil when the cover is not on disk yet —
    /// the caller then fetches the full image from the network as usual.
    func thumbnail(for url: URL) async -> UIImage? {
        await thumbnail(for: url, maxPixelSize: thumbPixelSize)
    }

    /// As above, but with a freely chosen target size (e.g. 800 px for the large
    /// "Up Next" cards). The cache is size-aware keyed so 400- and 800-px
    /// variants of the same cover do not overwrite each other.
    func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let fileKey = key(for: url)
        let cacheKey = "\(fileKey)@\(Int(maxPixelSize))" as NSString
        if let cached = thumbCache.object(forKey: cacheKey) {
            return cached
        }
        let candidates = [persistentDirectory, diskDirectory].map { $0.appendingPathComponent(fileKey) }
        // Disk read + decode off the MainActor — this runs per visible cell.
        let thumb = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            for file in candidates {
                if let data = try? Data(contentsOf: file) {
                    return Self.decodedThumbnail(data, maxPixelSize: maxPixelSize)
                }
            }
            return nil
        }.value
        guard let thumb else { return nil }
        thumbCache.setObject(thumb, forKey: cacheKey, cost: cost(of: thumb))
        return thumb
    }

    /// Pure decode-to-size without the re-encode `downsampled` does — thumbs
    /// never touch the disk.
    private nonisolated static func decodedThumbnail(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Full-size cached image. Memory-cache hits return immediately; the disk
    /// read + full decode run off-main (a ~2000 px decode on the main actor was
    /// a visible hitch right when pushing the detail screen / full player).
    func image(for url: URL) async -> UIImage? {
        let cacheKey = key(for: url)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        let candidates = [persistentDirectory, diskDirectory].map { $0.appendingPathComponent(cacheKey) }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            for fileURL in candidates {
                if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                    return image
                }
            }
            return nil
        }.value
        guard let image else { return nil }
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost(of: image))
        return image
    }

    /// Stores it reduced to display size (not pixelated, see maxPixelSize).
    /// Downsampling + disk write run in the background; the memory cache is then
    /// updated with the downsized version.
    func set(_ image: UIImage, data: Data, for url: URL) {
        let cacheKey = key(for: url)
        // Make it available immediately (original, cost-limited by NSCache).
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost(of: image))
        let target = diskDirectory.appendingPathComponent(cacheKey)
        let maxSize = maxPixelSize
        Task.detached(priority: .utility) {
            guard let stored = Self.downsampled(data, maxPixelSize: maxSize) else { return }
            try? stored.1.write(to: target, options: .atomic)
            await MainActor.run {
                ImageCache.shared.memoryCache.setObject(
                    stored.0, forKey: cacheKey as NSString,
                    cost: ImageCache.shared.cost(of: stored.0)
                )
            }
        }
    }

    /// Drop every cached representation (memory, thumbnails, disk) of a cover
    /// URL. Used when the server may have replaced the artwork behind an
    /// UNCHANGED id (e.g. a Navidrome re-tag) — the URL then still matches the
    /// old bytes, so a manual invalidation on refresh is the only way to pull
    /// the new cover.
    func invalidate(url: URL) {
        let cacheKey = key(for: url)
        memoryCache.removeObject(forKey: cacheKey as NSString)
        // Thumbnails are keyed "<fileKey>@<size>" — clear all size variants.
        thumbCache.removeAllObjects()
        let target = diskDirectory.appendingPathComponent(cacheKey)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Lift a downloaded book's cover into the persistent folder (move it out of
    /// the cache or fetch it fresh).
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
              let (data, _) = try? await URLSession.shared.data(from: coverURL) else { return }
        let maxSize = maxPixelSize
        // Downsampling + write in the background, await completion (the caller
        // relies on the cover being persistent afterwards).
        await Task.detached(priority: .utility) {
            guard let stored = Self.downsampled(data, maxPixelSize: maxSize) else { return }
            try? stored.1.write(to: target, options: .atomic)
        }.value
    }

    /// On deleting a download: move the persistent cover back into the purgeable
    /// cache (stays visible, but is now reclaimable).
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

    /// Cache files older than this are deleted — so a server-side CHANGED cover
    /// is re-fetched after this time at the latest (the cache key is
    /// deliberately path-stable and otherwise never invalidates).
    private let cacheTTL: TimeInterval = 30 * 24 * 3600
    /// Upper bound for the purgeable cover cache.
    private let maxCacheBytes = 200 * 1024 * 1024

    /// Maintenance pass, once per app start:
    /// 1) Persistent covers without an associated download back into the cache.
    /// 2) Delete cache files over TTL (cover refresh).
    /// 3) Cap the cache at maxCacheBytes, oldest first.
    func performMaintenance(activeDownloadIds: Set<String>) {
        // Pure file-system work — entirely in the background, not on the
        // MainActor (may touch hundreds of files with large libraries).
        let persistent = persistentDirectory
        let cache = diskDirectory
        let ttl = cacheTTL
        let maxBytes = maxCacheBytes
        Task.detached(priority: .utility) {
            let fm = FileManager.default

            // 1) Persistent covers without a download back into the cache.
            if let files = try? fm.contentsOfDirectory(at: persistent, includingPropertiesForKeys: nil) {
                for file in files {
                    let name = file.lastPathComponent
                    guard name.hasPrefix("_api_items_"), name.hasSuffix("_cover") else { continue }
                    let id = String(name.dropFirst("_api_items_".count).dropLast("_cover".count))
                    guard !activeDownloadIds.contains(id) else { continue }
                    let target = cache.appendingPathComponent(name)
                    if !fm.fileExists(atPath: target.path) {
                        try? fm.moveItem(at: file, to: target)
                    } else {
                        try? fm.removeItem(at: file)
                    }
                }
            }

            // 2) TTL + 3) size cap.
            guard let files = try? fm.contentsOfDirectory(
                at: cache,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return }
            var kept: [(url: URL, date: Date, size: Int)] = []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = values?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(date) > ttl {
                    try? fm.removeItem(at: file)
                } else {
                    kept.append((file, date, values?.fileSize ?? 0))
                }
            }
            var total = kept.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            for entry in kept.sorted(by: { $0.date < $1.date }) {
                try? fm.removeItem(at: entry.url)
                total -= entry.size
                if total <= maxBytes { break }
            }
        }
    }

    /// Size of the purgeable cover cache in bytes (for the settings).
    func cacheSizeBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Clears the purgeable cover cache (persistent download covers stay).
    func clearCache() {
        memoryCache.removeAllObjects()
        thumbCache.removeAllObjects()
        guard let files = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Whether a cover exists in the memory cache or on disk (no decode).
    private func isCached(_ url: URL) -> Bool {
        let cacheKey = key(for: url)
        if memoryCache.object(forKey: cacheKey as NSString) != nil { return true }
        return [persistentDirectory, diskDirectory].contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(cacheKey).path)
        }
    }

    /// Prefetches a cover in the background if it is not cached yet. Uses the
    /// timeouted Maer session (no forever-hanging request) and deduplicates
    /// parallel requests for the same cover.
    func preload(_ url: URL) async {
        // Existence check only — no need to decode the image just to know the
        // cover is already cached.
        guard !isCached(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)
        defer { inFlight.remove(url) }
        guard let (data, _) = try? await URLSession.maer.data(from: url),
              let image = UIImage(data: data) else { return }
        set(image, data: data, for: url)
    }
}
