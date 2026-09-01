// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

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
/// The line is `debug`, like the fetch line it replaces: a device run
/// reads it with `log show --level debug`, and a routine session pays
/// nothing for it.
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
                     attempt: Int, url: URL) {
        Logger.library.debug(
            "\(CoverTrace.line(pot: pot, outcome: outcome, attempt: attempt, url: url), privacy: .public)")
    }
}

/// Replacement for SwiftUI's `AsyncImage` that caches loaded images and retries
/// once automatically on a failed attempt. Solves the "sometimes there,
/// sometimes not" problem AsyncImage shows in scrollable grids/lists.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// True for small cells (grid, rows, mini player): display a ~400 px
    /// thumbnail derived from the cached cover instead of decoding the full
    /// ~2000 px image per cell. Far less RAM, smoother scrolling.
    var useThumbnail: Bool = false
    /// Target thumbnail size in pixels (nil → default ~400 px). Set higher for
    /// larger covers (e.g. 800 px) without decoding the full image.
    var thumbnailMaxPixel: CGFloat? = nil
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            // Prefer the loaded image; otherwise a synchronous warm-cache
            // peek so a re-entering cell renders its (display-ready) thumbnail on
            // frame 1. No placeholder flash, no async round-trip in the scroll
            // path. Cold cells fall back to the placeholder + async `load()`.
            if let img = uiImage ?? warmThumbnail {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            // A URL CHANGE on a long-lived view (drive-mode hero,
            // full-player cover) kept the PREVIOUS image on screen. Forever
            // when the new load failed ("foreign cover bleeds through").
            // Drop the stale image first; the warm-cache peek still renders
            // the new url's thumbnail frame-1 where cached, cold cells show
            // the placeholder (honest) instead of a wrong cover.
            if uiImage != nil { uiImage = nil }
            await load()
        }
    }

    /// Synchronous hit against the in-memory thumbnail cache (thumbnail cells only).
    private var warmThumbnail: UIImage? {
        guard uiImage == nil, useThumbnail, let url else { return nil }
        return ImageCache.shared.cachedThumbnail(for: url, maxPixelSize: thumbnailMaxPixel)
    }

    private func load() async {
        guard let url else { return }
        // Counted here, before an exit is picked, so a hit and a miss are
        // told apart by which pot answered and not by whether a line
        // appeared at all.
        let attempt = CoverTraceLog.attempt(for: url)
        // A cover already recognised as a service placeholder stays the
        // app placeholder for the session; no re-download per appearance.
        if ServicePlaceholderCovers.seen.contains(url) {
            CoverTraceLog.note(pot: .memo, outcome: .servicePlaceholder,
                               attempt: attempt, url: url)
            return
        }
        if useThumbnail {
            let thumb = thumbnailMaxPixel != nil
                ? await ImageCache.shared.thumbnail(for: url, maxPixelSize: thumbnailMaxPixel!)
                : await ImageCache.shared.thumbnail(for: url)
            if let thumb {
                uiImage = thumb
                CoverTraceLog.note(pot: .thumbnail, outcome: .hit,
                                   attempt: attempt, url: url)
                return
            }
        }
        if !useThumbnail, let cached = await ImageCache.shared.image(for: url) {
            uiImage = cached
            CoverTraceLog.note(pot: .full, outcome: .hit, attempt: attempt, url: url)
            return
        }
        // Thumbnail miss = cover not on disk yet: fall through to the
        // network fetch (fills the disk cache; next display uses the thumb),
        // coalesced so concurrent tiles of the same show share ONE download.
        if let image = await CoverFetchCoalescer.fetch(url, work: {
            await Self.fetch(url, retryDelay: nil, attempt: attempt)
        }) {
            uiImage = image
            return
        }
        // An automatic second attempt after a short pause. Covers most brief
        // network dropouts/server hiccups without the user having to do anything
        // manually.
        if let image = await CoverFetchCoalescer.fetch(url, work: {
            await Self.fetch(url, retryDelay: 800_000_000, attempt: attempt)
        }) {
            uiImage = image
        }
    }

    private static func fetch(_ url: URL, retryDelay: UInt64?, attempt: Int) async -> UIImage? {
        // Offline there is nothing to fetch. Per-cell attempts (incl. the
        // automatic retry) during scrolling just burn cycles and caused jitter
        // over sections with uncached covers.
        guard NetworkMonitor.shared.isConnected else {
            CoverTraceLog.note(pot: .network, outcome: .offline, attempt: attempt, url: url)
            return nil
        }
        if let retryDelay {
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        // Funkwhale compat: getCoverArt can answer with a JSON
        // error body. The UIImage decode gate below treats ANY non-image
        // payload as a miss (placeholder), and nothing non-image is ever
        // cached (the disk paths gate on downsampling the same way).
        guard let (data, _) = try? await URLSession.coverImage.data(from: url) else {
            CoverTraceLog.note(pot: .network, outcome: .transport, attempt: attempt, url: url)
            return nil
        }
        // The archive item-image service never says "no picture"; it
        // answers with its pillar logo or a waveform strip instead. Those
        // are recognised HERE, where the bytes already are (no extra
        // request), and the tile keeps the honest placeholder. Never
        // cached, so an item that gains artwork shows it next session.
        if FreeCatalog.isArchiveServicePlaceholder(data: data, url: url) {
            ServicePlaceholderCovers.seen.insert(url)
            CoverTraceLog.note(pot: .network, outcome: .servicePlaceholder,
                               attempt: attempt, url: url)
            return nil
        }
        guard let image = UIImage(data: data) else {
            CoverTraceLog.note(pot: .network, outcome: .undecodable, attempt: attempt, url: url)
            return nil
        }
        ImageCache.shared.set(image, data: data, for: url)
        CoverTraceLog.note(pot: .network, outcome: .hit, attempt: attempt, url: url)
        return image
    }
}
