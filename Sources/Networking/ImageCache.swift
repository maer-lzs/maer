// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import ImageIO
import OSLog
import CryptoKit

/// Two-tier cache for cover images: memory + disk. Disk in TWO tiers:
/// - `Caches/CoverCache`: normal library. iOS may purge it under memory pressure.
/// - `Application Support/Covers`: covers of DOWNLOADED books. Persistent, so
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
    /// and stutters scrolling with large libraries. Memory-only. Always
    /// derivable from the disk tiers.
    private let thumbCache = NSCache<NSString, UIImage>()
    /// The one default thumbnail size, for the cache and for every cell that
    /// asks the door without naming a size.
    nonisolated static let defaultThumbnailPixel: CGFloat = 400
    private let thumbPixelSize: CGFloat = ImageCache.defaultThumbnailPixel
    /// Every preview size the app asks for. They are ours, not the
    /// server's. So an invalidation can name them instead of emptying the
    /// whole store. A new size belongs in here; the fence holds that.
    nonisolated static let thumbnailVariants: [CGFloat] = [400, 600]

    /// How many images each cache is MEANT to hold. The cost limit is
    /// derived from this instead of written down beside it, because two
    /// limits stating different numbers let the smaller one bind invisibly.
    /// Previews get the larger share, because they are what every row and
    /// every grid needs; full images stand on screen once or twice.
    nonisolated static let thumbBudget = 240
    nonisolated static let fullCoverBudget = 6

    private let diskDirectory: URL
    private let persistentDirectory: URL

    /// Device-adaptive storage size (longest side): screen short side in
    /// pixels × 1.6 headroom. Plain 1× turned out visibly soft on modern
    /// iPhones. Clamped to 1500 (older, low-res devices don't need more)
    /// … 2200 (above the iPad-Pro hero width is invisible overhead).
    /// Modern iPhones land at ~1900–2100, iPads at 2200.
    private let maxPixelSize: CGFloat

    private init() {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        let shortSidePixels = screen.map { min($0.bounds.width, $0.bounds.height) * $0.scale } ?? 1500
        maxPixelSize = min(2200, max(1500, shortSidePixels * 1.6))
        // Tile rows threw their images away again as soon as one scrolled
        // sideways. Both caches carried TWO limits meaning different numbers,
        // and the smaller one bound without the larger one showing it. Worked
        // out:
        //
        //   preview  400 x 400 x 4  =   640 kB  →  40 MB held ~62 images,
        //                                          NOT the stated 600.
        //   full    ~2000 x 2000 x 4 = ~16 MB   → 150 MB held ~9 images,
        //                                          NOT the stated 300.
        //
        // A SINGLE row shows twelve tiles and the start surface carries six
        // rows, so the cache was full after two or three rows and every
        // returning tile found nothing. Exactly the symptom.
        //
        // The split was also the inverse of the use: the rendering every row
        // and every grid needs had a quarter of the budget of the rendering
        // that stands on screen once or twice. Now both limits state the same
        // number PER cache, so neither is decoration.
        //
        // The limit IS the arithmetic, so it cannot drift from the count
        // written beside it.
        memoryCache.countLimit = Self.fullCoverBudget
        memoryCache.totalCostLimit = Self.fullCoverBudget * Int(maxPixelSize * maxPixelSize) * 4
        thumbCache.countLimit = Self.thumbBudget
        thumbCache.totalCostLimit = Self.thumbBudget * Int(thumbPixelSize * thumbPixelSize) * 4
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
    /// cache key (Subsonic sends a fresh salt+token every call). `nonisolated`:
    /// immutable Sendable set read from the nonisolated `key(for:)`.
    /// Auth salt in the query is never part of the key: Subsonic rotates
    /// `t`/`s` per request, Audiobookshelf carries its session `token` and
    /// Jellyfin its `ApiKey` (the `api_key` name stays for covers cached by
    /// an older build). A key that carried the token missed on every login
    /// AND, at roughly 300 characters, exceeded the file system's 255-byte
    /// name limit, so the cover file was never written and every appearance
    /// of an audiobook tile fetched again.
    nonisolated private static let volatileQueryParams: Set<String> =
        ["t", "s", "u", "c", "v", "f", "p", "token", "api_key", "ApiKey"]

    /// APFS refuses names over 255 bytes. A key beyond `keyByteCeiling`
    /// becomes its digest, so no future long query can silently disable
    /// the disk cache the way the token did.
    nonisolated private static let keyByteCeiling = 200

    /// Host + path + the STABLE query params (e.g. Subsonic `id`/`size`). Path
    /// alone collided every Subsonic cover onto one key. Their identifying
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
        let raw = parts.joined(separator: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard raw.utf8.count > Self.keyByteCeiling else { return raw }
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The ONE file name for a cover, in the cache and in the persistent
    /// store alike. A second derivation from the item id (without host)
    /// once wrote persistent covers under a name no read path looked up,
    /// so the offline cover of a downloaded book never existed.
    nonisolated func fileKey(for url: URL) -> String { key(for: url) }

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
    /// from the disk tiers. Returns nil when the cover is not on disk yet.
    /// The caller then fetches the full image from the network as usual.
    func thumbnail(for url: URL) async -> UIImage? {
        await thumbnail(for: url, maxPixelSize: thumbPixelSize)
    }

    /// Synchronous memory-cache peek (no disk, no decode). Lets a cell show
    /// a WARM, already display-ready thumbnail on its very first frame instead of
    /// flashing the placeholder and awaiting a round-trip each time it re-enters
    /// the viewport. Takes the warm-cover cost fully out of the scroll path.
    func cachedThumbnail(for url: URL, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let cacheKey = "\(key(for: url))@\(Int(maxPixelSize ?? thumbPixelSize))" as NSString
        return thumbCache.object(forKey: cacheKey)
    }

    /// As above, but with a freely chosen target size (e.g. 800 px for the large
    /// "Up Next" cards). The cache is size-aware keyed so 400- and 800-px
    /// variants of the same cover do not overwrite each other.
    func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let fileKey = key(for: url)
        let cacheKey = "\(fileKey)@\(Int(maxPixelSize))" as NSString
        if let cached = thumbCache.object(forKey: cacheKey) {
            // A warm hit returns a display-ready image (see decodedThumbnail).
            // No main-thread decode at draw time.
            PerfSignpost.cover.emitEvent("thumb-hit")
            return cached
        }
        let candidates = [persistentDirectory, diskDirectory].map { $0.appendingPathComponent(fileKey) }
        // Disk read + decode off the MainActor. This runs per visible cell.
        // detached because disk read and decode run per visible cell, off the MainActor
        let thumb = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Regression guard: disk read + image decode stay off the main actor.
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
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

    /// Cache first, NETWORK second. And it reports the SOURCE size alongside
    /// the display image.
    ///
    /// Both read methods above deliberately never fetch: they are the read side
    /// of a cache that other surfaces fill. Radio artwork had no such filling
    /// surface. It resolved a logo URL and then asked a cache that could only
    /// ever answer for pictures something ELSE had downloaded. That is why a
    /// station logo appeared only after the station had been played once: the
    /// player's cover view is what fetched it.
    ///
    /// The source size travels with the image because the quality gate has to
    /// judge the picture that ARRIVED. Judging the 400-px thumbnail instead
    /// rejects exactly the wide wordmarks the 800-px render exists for. A
    /// 800×92 logo becomes 400×46 and falls under the 48-px floor.
    func loadedImage(for url: URL, maxPixelSize: CGFloat? = nil)
        async -> (image: UIImage, sourcePixels: CGSize)? {
        let target = maxPixelSize ?? thumbPixelSize
        if let cached = await thumbnail(for: url, maxPixelSize: target),
           let full = await image(for: url) {
            return (cached, CGSize(width: full.size.width * full.scale,
                                   height: full.size.height * full.scale))
        }
        guard let (data, _) = try? await HTTP.data(from: url, lane: .cover),
              let full = UIImage(data: data) else { return nil }
        set(full, data: data, for: url)
        let display = Self.decodedThumbnail(data, maxPixelSize: target) ?? full
        return (display, CGSize(width: full.size.width * full.scale,
                                height: full.size.height * full.scale))
    }

    /// What ImageIO makes of these bytes. The door's second try when
    /// UIKit's reader says no: ImageIO reads formats UIKit does not,
    /// `.ico` among them, which is what a station's own site serves as its
    /// icon. The same decoder the thumbnails use, at the ceiling of a full
    /// cover, so this is one mechanic with a parameter, not a second one.
    nonisolated static func decoded(_ data: Data) -> UIImage? {
        decodedThumbnail(data, maxPixelSize: thumbnailVariants.max() ?? defaultThumbnailPixel)
    }

    /// Pure decode-to-size without the re-encode `downsampled` does. Thumbs
    /// never touch the disk.
    private nonisolated static func decodedThumbnail(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sp = PerfSignpost.cover.beginInterval("decode")
        defer { PerfSignpost.cover.endInterval("decode", sp) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Force the pixel decode NOW, off the main actor, into a
        // display-ready bitmap. `CGImageSourceCreateThumbnailAtIndex` returns a
        // lazily-decoded image; without this the render server decodes it on the
        // MAIN thread at first draw. The exact hitch when the Downloaded rows
        // (and any thumbnail cell) enter the viewport and rebuild. Runs here
        // inside the detached decode task, so it stays off the main thread.
        return UIImage(cgImage: cg).preparingForDisplay() ?? UIImage(cgImage: cg)
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
        // detached because disk read and decode belong off the MainActor
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
        // detached because downsample and write are CPU and disk work off the MainActor and must finish once started
        Task.detached(priority: .utility) {
            guard let stored = Self.downsampled(data, maxPixelSize: maxSize) else { return }
            do {
                try stored.1.write(to: target, options: .atomic)
            } catch {
                // A cover that cannot be written is fetched again on
                // every appearance; a swallowed error here hides exactly
                // that. Path stays out of the log, the name is the key.
                Logger.library.error("COVERCACHE write failed: \(FailureReason.of(error), privacy: .public)")
            }
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
    /// UNCHANGED id (e.g. a Navidrome re-tag). The URL then still matches the
    /// old bytes, so a manual invalidation on refresh is the only way to pull
    /// the new cover.
    func invalidate(url: URL) {
        let cacheKey = key(for: url)
        memoryCache.removeObject(forKey: cacheKey as NSString)
        // This used to be `removeAllObjects()`. ONE url emptied EVERY
        // preview in the app. Its only caller runs in a loop over hundreds of
        // entries on pull-to-refresh, so one pull cleared the previews of
        // every tab, several hundred times over. The size variants are known
        // (they are OUR parameter, not the server's), so they are removed by
        // name: the invalidation now costs what it claims to cost.
        for size in Self.thumbnailVariants {
            thumbCache.removeObject(forKey: "\(cacheKey)@\(Int(size))" as NSString)
        }
        let target = diskDirectory.appendingPathComponent(cacheKey)
        // detached because the write is disk work off the MainActor and must finish once started
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Lift a downloaded book's cover into the persistent folder (move it out of
    /// the cache or fetch it fresh).
    /// Keeps the cover of a downloaded item outside the purgeable cache,
    /// under the SAME name the read paths use. A cached copy is moved,
    /// otherwise the bytes are fetched once.
    func makePersistent(coverURL: URL?) async {
        guard let coverURL else { return }
        let cacheKey = key(for: coverURL)
        let target = persistentDirectory.appendingPathComponent(cacheKey)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let cached = diskDirectory.appendingPathComponent(cacheKey)
        if FileManager.default.fileExists(atPath: cached.path) {
            do {
                try FileManager.default.moveItem(at: cached, to: target)
                return
            } catch {
                Logger.library.error("COVERCACHE persist move failed: \(FailureReason.of(error), privacy: .public)")
            }
        }
        guard let (data, _) = try? await HTTP.data(from: coverURL, lane: .cover) else { return }
        await makePersistent(coverURL: coverURL, data: data)
    }

    /// The write half, with the bytes in hand. Separate so a test can
    /// hand in a picture without a network.
    func makePersistent(coverURL: URL, data: Data) async {
        let target = persistentDirectory.appendingPathComponent(key(for: coverURL))
        let maxSize = maxPixelSize
        // Downsampling + write in the background, await completion (the caller
        // relies on the cover being persistent afterwards).
        // detached because downsample and write are CPU and disk work off the MainActor and must finish once started
        await Task.detached(priority: .utility) {
            guard let stored = Self.downsampled(data, maxPixelSize: maxSize) else { return }
            do {
                try stored.1.write(to: target, options: .atomic)
            } catch {
                // Silence here would mean an offline book without its
                // cover and nobody knowing why.
                Logger.library.error("COVERCACHE persist write failed: \(FailureReason.of(error), privacy: .public)")
            }
        }.value
    }

    /// On deleting a download: move the persistent cover back into the purgeable
    /// cache (stays visible, but is now reclaimable).
    /// The persistent copy goes back into the cache when the download
    /// goes; the picture stays available until the cache lets it go.
    func removePersistent(coverURL: URL?) {
        guard let coverURL else { return }
        let cacheKey = key(for: coverURL)
        let source = persistentDirectory.appendingPathComponent(cacheKey)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let target = diskDirectory.appendingPathComponent(cacheKey)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.removeItem(at: source)
            }
        } catch {
            Logger.library.error("COVERCACHE unpersist failed: \(FailureReason.of(error), privacy: .public)")
        }
    }

    /// Cache files older than this are deleted. So a server-side CHANGED cover
    /// is re-fetched after this time at the latest (the cache key is
    /// deliberately path-stable and otherwise never invalidates).
    private let cacheTTL: TimeInterval = 30 * 24 * 3600
    /// Upper bound for the purgeable cover cache.
    /// The fixed 200 MB cap became adaptive. Reasoning behind the
    /// numbers, and why the risk is asymmetric: the cache lives in Caches,
    /// is excluded from backup and gets purged by iOS under pressure. Too
    /// large costs practically nothing, too small costs permanently (evict →
    /// re-download → the reload stutter over uncached areas). At ~300–600 KB
    /// per cover, 200 MB held only 400–600 covers: plenty for audiobooks,
    /// too tight for a four-digit music library.
    ///
    /// Pure so it is testable without a device: the smaller of an upper
    /// bound and a small share of the FREE space, never below the floor (a
    /// full device must not shrink the cache to nothing).
    nonisolated static func cacheCapBytes(freeBytes: Int64) -> Int64 {
        let upper: Int64 = 500 * 1024 * 1024
        let floor: Int64 = 150 * 1024 * 1024
        let share = Int64(Double(max(freeBytes, 0)) * 0.05)
        return max(floor, min(upper, share))
    }

    nonisolated static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private var maxCacheBytes: Int { Int(Self.cacheCapBytes(freeBytes: Self.freeDiskBytes())) }

    /// Enforcement no longer waits for the next app start when the
    /// cache has run far past the cap. This is the factor that triggers an
    /// extra pass at the next calm moment.
    nonisolated static let enforcementOvershoot = 1.5

    /// Maintenance pass, once per app start:
    /// 1) Persistent covers without an associated download back into the cache.
    /// 2) Delete cache files over TTL (cover refresh).
    /// 3) Cap the cache at maxCacheBytes, oldest first.
    /// `activeCoverURLs`: the covers of everything still downloaded. Any
    /// other file in the persistent store is an orphan and goes back to
    /// the cache. Membership is decided by the file NAME the covers would
    /// carry, so a digest key and a plain key are treated alike.
    /// `onlyWhenOverCap`: the extra pass that used to be gated by a
    /// separate check on the caller's side. It asked `cacheSizeBytes()`,
    /// which enumerates the whole cache directory and reads a size per
    /// file, ON THE MAIN ACTOR, at every return to the app. Measured: 3 ms
    /// at a thousand covers, 6.6 ms at two thousand (the size the device
    /// log showed), 13.8 ms at four thousand, against a frame of 16.7 ms.
    /// **The guard cost more than what it guarded, and it was paid on the
    /// more expensive thread**, to answer a question whose answer is almost
    /// always no (the device log shows `evicted=0` over and over).
    ///
    /// So the question moved in here, where a sweep runs off the main actor
    /// anyway, and the directory is now enumerated ONCE instead of twice.
    func performMaintenance(activeCoverURLs: [URL], onlyWhenOverCap: Bool = false) {
        // Pure file-system work. Entirely in the background, not on the
        // MainActor (may touch hundreds of files with large libraries).
        let persistent = persistentDirectory
        let cache = diskDirectory
        let ttl = cacheTTL
        let free = Self.freeDiskBytes()
        let maxBytes = Int(Self.cacheCapBytes(freeBytes: free))
        let activeNames = Set(activeCoverURLs.map { key(for: $0) })
        let started = Date()
        // detached because the sweep is disk work off the MainActor and must not die with the caller
        Task.detached(priority: .utility) {
            if onlyWhenOverCap,
               Self.directoryBytes(cache) <= Int64(Double(maxBytes) * Self.enforcementOvershoot) {
                return
            }
            let fm = FileManager.default

            // 1) Persistent covers without a download back into the cache.
            if let files = try? fm.contentsOfDirectory(at: persistent, includingPropertiesForKeys: nil) {
                for file in files {
                    let name = file.lastPathComponent
                    guard !activeNames.contains(name) else { continue }
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
            var sweptPlaceholders = 0
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = values?.contentModificationDate ?? .distantPast
                // Service placeholders CACHED before the fetch gate
                // existed: a pillar logo or waveform strip that was
                // stored as a cover keeps serving from here until the
                // TTL. Judged with the same probe as the gate, scoped
                // by file name to the item image service, so no
                // foreign cover pays a read.
                if file.lastPathComponent.contains("_services_img_"),
                   let data = try? Data(contentsOf: file),
                   ArchiveServicePlaceholder.isPlaceholderBody(data) {
                    try? fm.removeItem(at: file)
                    sweptPlaceholders += 1
                    continue
                }
                if Date().timeIntervalSince(date) > ttl {
                    try? fm.removeItem(at: file)
                } else {
                    kept.append((file, date, values?.fileSize ?? 0))
                }
            }
            if sweptPlaceholders > 0 {
                Logger.library.notice("COVERCACHE swept \(sweptPlaceholders) service placeholder(s)")
            }
            var total = kept.reduce(0) { $0 + $1.size }
            let startTotal = total
            var evicted = 0
            if total > maxBytes {
                for entry in kept.sorted(by: { $0.date < $1.date }) {
                    try? fm.removeItem(at: entry.url)
                    total -= entry.size
                    evicted += 1
                    if total <= maxBytes { break }
                }
            }
            // Measurable instead of guessed. How many covers, their bytes,
            // the cap, free space, how many went and how long the sweep
            // took: the numbers a directory-as-rows decision needs.
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.library.notice("COVERCACHE sweep covers=\(kept.count) size=\(startTotal / 1_048_576)MB cap=\(maxBytes / 1_048_576)MB free=\(free / 1_048_576)MB evicted=\(evicted) ms=\(ms)")
        }
    }

    /// Bytes in a directory. A full enumeration with a size read per file,
    /// so it belongs off the main actor; `nonisolated` so the sweep's own
    /// task can call it without hopping back.
    nonisolated static func directoryBytes(_ dir: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Size of the purgeable cover cache in bytes. The SETTINGS ask this,
    /// and there it is the answer being shown, so paying for it is the
    /// point. Nothing on a render path may ask it.
    func cacheSizeBytes() -> Int64 { Self.directoryBytes(diskDirectory) }

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
        // Existence check only. No need to decode the image just to know the
        // cover is already cached.
        guard !isCached(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)
        defer { inFlight.remove(url) }
        guard let (data, _) = try? await HTTP.data(from: url, lane: .cover),
              let image = UIImage(data: data) else { return }
        set(image, data: data, for: url)
    }
}
