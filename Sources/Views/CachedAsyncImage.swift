// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Replacement for SwiftUI's `AsyncImage` that caches loaded images and retries
/// once automatically on a failed attempt. Solves the "sometimes there,
/// sometimes not" problem AsyncImage shows in scrollable grids/lists.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// True for small cells (grid, rows, mini player): display a ~400 px
    /// thumbnail derived from the cached cover instead of decoding the full
    /// ~2000 px image per cell — far less RAM, smoother scrolling.
    var useThumbnail: Bool = false
    /// Target thumbnail size in pixels (nil → default ~400 px). Set higher for
    /// larger covers (e.g. 800 px) without decoding the full image.
    var thumbnailMaxPixel: CGFloat? = nil
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            // S16: prefer the loaded image; otherwise a synchronous warm-cache
            // peek so a re-entering cell renders its (display-ready) thumbnail on
            // frame 1 — no placeholder flash, no async round-trip in the scroll
            // path. Cold cells fall back to the placeholder + async `load()`.
            if let img = uiImage ?? warmThumbnail {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            // af3ec41: a URL CHANGE on a long-lived view (drive-mode hero,
            // full-player cover) kept the PREVIOUS image on screen — forever
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
        if useThumbnail {
            let thumb = thumbnailMaxPixel != nil
                ? await ImageCache.shared.thumbnail(for: url, maxPixelSize: thumbnailMaxPixel!)
                : await ImageCache.shared.thumbnail(for: url)
            if let thumb { uiImage = thumb; return }
        }
        if !useThumbnail, let cached = await ImageCache.shared.image(for: url) {
            uiImage = cached
            return
        }
        // Thumbnail miss = cover not on disk yet: fall through to the
        // network fetch (fills the disk cache; next display uses the thumb).
        if let image = await fetch(url, retryDelay: nil) {
            uiImage = image
            return
        }
        // An automatic second attempt after a short pause — covers most brief
        // network dropouts/server hiccups without the user having to do anything
        // manually.
        if let image = await fetch(url, retryDelay: 800_000_000) {
            uiImage = image
        }
    }

    private func fetch(_ url: URL, retryDelay: UInt64?) async -> UIImage? {
        // A6: offline there is nothing to fetch — per-cell attempts (incl. the
        // automatic retry) during scrolling just burn cycles and caused jitter
        // over sections with uncached covers.
        guard NetworkMonitor.shared.isConnected else { return nil }
        if let retryDelay {
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        // Funkwhale compat (170ff18): getCoverArt can answer with a JSON
        // error body — the UIImage decode gate below treats ANY non-image
        // payload as a miss (placeholder), and nothing non-image is ever
        // cached (the disk paths gate on downsampling the same way).
        guard let (data, _) = try? await URLSession.coverImage.data(from: url),
              let image = UIImage(data: data) else { return nil }
        ImageCache.shared.set(image, data: data, for: url)
        return image
    }
}
