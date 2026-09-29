// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import OSLog

/// THE door for pictures. Every surface that shows, colours, persists or
/// sweeps a cover asks here; nothing outside this file, the cache behind it
/// and the byte probe decodes image bytes or calls the cover lane itself.
///
/// Behind the door: the three cache tiers (memory, purgeable disk,
/// persistent disk) with the downsample rule in `ImageCache`, the one
/// network path with the coalescer (one fetch per address at a time), the
/// service-placeholder gate, the cover trace, and the sweep. Bytes travel
/// only over the cover lane of the HTTP door.
@MainActor
enum Artwork {
    /// One answer of the picture question: the display image and the pot
    /// it came from (the tile marker names it: memo, thumb, full, net, net2).
    struct Answer {
        let image: UIImage
        let pot: String
    }

    // MARK: - Reading

    /// The picture for an address, at thumbnail size when `thumbnail` names
    /// one, else the full image: memory or disk first, the network second
    /// (coalesced with every other caller of the same address, one automatic
    /// second attempt), and every exit says which pot answered.
    static func image(for url: URL, thumbnail maxPixel: CGFloat? = nil,
                      attempt known: Int? = nil) async -> Answer? {
        let attempt = known ?? CoverTraceLog.attempt(for: url)
        // A cover already recognised as a service placeholder stays the
        // app placeholder for the session; no re-download per appearance.
        if ServicePlaceholderCovers.seen.contains(url) {
            CoverTraceLog.note(pot: .memo, outcome: .servicePlaceholder, attempt: attempt, url: url)
            return nil
        }
        if let maxPixel {
            if let thumb = await ImageCache.shared.thumbnail(for: url, maxPixelSize: maxPixel) {
                CoverTraceLog.note(pot: .thumbnail, outcome: .hit, attempt: attempt, url: url)
                return Answer(image: thumb, pot: "thumb")
            }
        } else if let cached = await ImageCache.shared.image(for: url) {
            CoverTraceLog.note(pot: .full, outcome: .hit, attempt: attempt, url: url)
            return Answer(image: cached, pot: "full")
        }
        // Not on disk yet: the network fills the disk cache; the next
        // display finds the thumbnail there.
        if let image = await CoverFetchCoalescer.fetch(url, work: {
            await fetch(url, retryDelay: nil, attempt: attempt)
        }) {
            return Answer(image: image, pot: "net")
        }
        // An automatic second attempt after a short pause covers most brief
        // network dropouts without the person doing anything.
        if let image = await CoverFetchCoalescer.fetch(url, work: {
            await fetch(url, retryDelay: 800_000_000, attempt: attempt)
        }) {
            return Answer(image: image, pot: "net2")
        }
        return nil
    }

    /// The thumbnail from memory or disk, never the network.
    static func thumbnail(for url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        if let maxPixel { return await ImageCache.shared.thumbnail(for: url, maxPixelSize: maxPixel) }
        return await ImageCache.shared.thumbnail(for: url)
    }

    /// Synchronous warm peek: a display-ready thumbnail for the first frame.
    static func cachedThumbnail(for url: URL, maxPixel: CGFloat? = nil) -> UIImage? {
        ImageCache.shared.cachedThumbnail(for: url, maxPixelSize: maxPixel)
    }

    /// The full image from memory or disk, never the network.
    static func full(for url: URL) async -> UIImage? {
        await ImageCache.shared.image(for: url)
    }

    /// The picture WITH the size it arrived in, cache first, network second:
    /// the radio quality gate judges the source, not the thumbnail.
    static func loaded(for url: URL, maxPixel: CGFloat? = nil)
        async -> (image: UIImage, sourcePixels: CGSize)? {
        await ImageCache.shared.loadedImage(for: url, maxPixelSize: maxPixel)
    }

    /// A picture as a file for a caller that hands it on whole (the
    /// LibriVox import sends the cover with the upload): streamed over the
    /// cover lane to a temporary file the caller moves. Not cached; an
    /// import package is not a display.
    static func file(for url: URL) async throws -> URL {
        let (downloaded, _) = try await HTTP.download(from: url, lane: .cover)
        return downloaded
    }

    /// Fetch a cover into the cache ahead of its first display.
    static func preload(_ url: URL) async {
        await ImageCache.shared.preload(url)
    }

    // MARK: - Keeping and forgetting

    /// A downloaded item's cover leaves the purgeable tier for the
    /// persistent one (moved, or fetched once).
    static func persist(_ url: URL?) async {
        await ImageCache.shared.makePersistent(coverURL: url)
    }

    /// The write half with the bytes in hand.
    static func persist(_ url: URL, data: Data) async {
        await ImageCache.shared.makePersistent(coverURL: url, data: data)
    }

    /// The persistent copy goes back to the purgeable tier.
    static func forget(_ url: URL?) {
        ImageCache.shared.removePersistent(coverURL: url)
    }

    /// Every cached representation of an address is dropped: the server may
    /// have replaced the artwork behind an unchanged id.
    static func invalidate(_ url: URL) {
        ImageCache.shared.invalidate(url: url)
    }

    // MARK: - Sweeping

    /// The sweep: orphaned persistent covers back to the cache, files over
    /// the TTL and over the cap out; measured in the log.
    static func sweep(active: [URL]) {
        ImageCache.shared.performMaintenance(activeCoverURLs: active)
    }

    /// The extra pass on returning to the app, for a session that has run
    /// far past the cap. It decides INSIDE the sweep's own background task
    /// whether there is anything to do, because the deciding question is a
    /// full directory enumeration and used to be asked on the main actor.
    static func sweepIfOverCap(active: [URL]) {
        ImageCache.shared.performMaintenance(activeCoverURLs: active, onlyWhenOverCap: true)
    }

    static func cacheSizeBytes() -> Int64 {
        ImageCache.shared.cacheSizeBytes()
    }

    static func clearCache() {
        ImageCache.shared.clearCache()
    }

    // MARK: - The one network path

    private static func fetch(_ url: URL, retryDelay: UInt64?, attempt: Int) async -> UIImage? {
        // Offline there is nothing to fetch. Per-cell attempts during
        // scrolling would only burn cycles.
        guard NetworkMonitor.shared.isConnected else {
            CoverTraceLog.note(pot: .network, outcome: .offline, attempt: attempt, url: url)
            return nil
        }
        if let retryDelay {
            // bearable, because a cancelled sleep only drops the second attempt
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        // A server can answer a cover address with a JSON error body
        // (Funkwhale). The decode gate treats any non-image payload as a
        // miss, and nothing non-image is ever cached.
        // bearable, because the HTTP door logs the failure with its reason and the trace names it as transport
        guard let (data, _) = try? await HTTP.data(from: url, lane: .cover) else {
            CoverTraceLog.note(pot: .network, outcome: .transport, attempt: attempt, url: url)
            return nil
        }
        // The archive item-image service never says "no picture"; it
        // answers with its pillar logo or a waveform strip. Recognised here,
        // where the bytes already are, never cached, so an item that gains
        // artwork shows it next session.
        if ArchiveServicePlaceholder.isPlaceholder(data: data, url: url) {
            ServicePlaceholderCovers.seen.insert(url)
            CoverTraceLog.note(pot: .network, outcome: .servicePlaceholder, attempt: attempt, url: url)
            return nil
        }
        // `UIImage(data:)` reads what UIKit knows; ImageIO reads more,
        // among them the `.ico` a station's own site serves as its icon.
        // The second try costs nothing on the path that already failed.
        guard let image = UIImage(data: data) ?? ImageCache.decoded(data) else {
            CoverTraceLog.note(pot: .network, outcome: .undecodable, attempt: attempt,
                               url: url, bytes: data.count)
            return nil
        }
        ImageCache.shared.set(image, data: data, for: url)
        CoverTraceLog.note(pot: .network, outcome: .hit, attempt: attempt, url: url)
        return image
    }
}

/// Session memory for cover addresses whose answer turned out to be a
/// service placeholder (archive's pillar logo, a derived waveform strip).
/// Not persisted: the item may gain real artwork, and a 2 kB probe per
/// session is cheap. Without this every appearance of the tile downloads
/// the same non-cover again.
@MainActor
enum ServicePlaceholderCovers {
    static var seen: Set<URL> = []
}

/// One network fetch per cover URL at a time. Two surfaces showing the
/// same show raced each other to the first cache write and BOTH paid the
/// download (measured: 8 of 56 fetches in a cold scroll pass were such
/// twins). The second caller now awaits the first one's task instead.
@MainActor
enum CoverFetchCoalescer {
    static var inFlight: [URL: Task<UIImage?, Never>] = [:]

    static func fetch(_ url: URL, work: @escaping () async -> UIImage?) async -> UIImage? {
        if let running = inFlight[url] { return await running.value }
        let task = Task { await work() }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        return image
    }
}

/// The chain's own voice. Main-actor bound because every caller sits on
/// the view; a lock would buy nothing and cost a hop in the scroll path.
///
/// The line is `notice`: a device archive keeps `notice` and above,
/// while `debug` stays in the ring buffer and never reaches
/// `log collect`. The line exists to be read from exactly such an
/// archive, so any lower level would make it silent where it matters.
@MainActor
enum CoverTraceLog {
    private static var counter = CoverTrace.Counter()

    /// The attempt number for this address, counted before the chain
    /// picks an exit so every exit can name it.
    static func attempt(for url: URL) -> Int {
        if counter.trackedAddresses >= CoverTrace.addressCeiling { counter.reset() }
        return counter.next(for: url)
    }

    static func note(pot: CoverTrace.Pot, outcome: CoverTrace.Outcome,
                     attempt: Int, url: URL, bytes: Int? = nil) {
        Logger.library.notice(
            "\(CoverTrace.line(pot: pot, outcome: outcome, attempt: attempt, url: url, bytes: bytes), privacy: .public)")
    }
}
