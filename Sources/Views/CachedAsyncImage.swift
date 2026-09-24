// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// The attempt number the cover chain counted for the picture a builder
/// is showing. Zero means "not counted", which only a builder outside
/// the chain ever sees.
private struct CoverLoadAttemptKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct CoverLoadPotKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var coverLoadPot: String {
        get { self[CoverLoadPotKey.self] }
        set { self[CoverLoadPotKey.self] = newValue }
    }
    var coverLoadAttempt: Int {
        get { self[CoverLoadAttemptKey.self] }
        set { self[CoverLoadAttemptKey.self] = newValue }
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
    /// The builder always receives the pixel size alongside the image.
    /// This view is the only place that HAS it: everything downstream is
    /// handed a SwiftUI `Image`, which does not report its dimensions,
    /// and a caller that wants to decide by shape would otherwise have to
    /// load the picture a second time.
    private let sizedContent: (Image, CGSize) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    /// The plain form: the builder only wants the picture.
    init(url: URL?, useThumbnail: Bool = false, thumbnailMaxPixel: CGFloat? = nil,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.useThumbnail = useThumbnail
        self.thumbnailMaxPixel = thumbnailMaxPixel
        self.sizedContent = { image, _ in content(image) }
        self.placeholder = placeholder
    }

    /// The form for builders that decide by SHAPE. The size is in pixels
    /// of the image actually being shown, so a thumbnail reports the
    /// thumbnail's size; the proportion is the same either way, and the
    /// proportion is what the decision reads.
    init(url: URL?, useThumbnail: Bool = false, thumbnailMaxPixel: CGFloat? = nil,
         @ViewBuilder sized: @escaping (Image, CGSize) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.useThumbnail = useThumbnail
        self.thumbnailMaxPixel = thumbnailMaxPixel
        self.sizedContent = sized
        self.placeholder = placeholder
    }

    @State private var uiImage: UIImage?
    /// How often THIS address has been asked for, and which pot answered
    /// last, handed down to the content so a surface can show them
    /// (see `CoverMarker`).
    @State private var loadAttempt = 0
    @State private var loadPot = ""

    var body: some View {
        Group {
            // Prefer the loaded image; otherwise a synchronous warm-cache
            // peek so a re-entering cell renders its (display-ready) thumbnail on
            // frame 1. No placeholder flash, no async round-trip in the scroll
            // path. Cold cells fall back to the placeholder + async `load()`.
            if let img = uiImage ?? warmThumbnail {
                sizedContent(Image(uiImage: img), img.size)
                    .environment(\.coverLoadAttempt, loadAttempt)
                    .environment(\.coverLoadPot, loadPot)
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
        return Artwork.cachedThumbnail(for: url, maxPixel: thumbnailMaxPixel)
    }

    /// The view asks the ONE door; cache tiers, coalescing, the placeholder
    /// gate and the trace live behind it. The attempt is counted here so the
    /// tile marker can name it even when the door answers nothing.
    private func load() async {
        guard let url else { return }
        let attempt = CoverTraceLog.attempt(for: url)
        loadAttempt = attempt
        let thumbnail = useThumbnail ? (thumbnailMaxPixel ?? ImageCache.defaultThumbnailPixel) : nil
        let answer = await Artwork.image(for: url, thumbnail: thumbnail, attempt: attempt)
        // The address changed while the door answered: `.task(id:)` cancelled
        // this load, and its answer belongs to the PREVIOUS address. Written
        // anyway, it put one show's cover on another's episode.
        guard !Task.isCancelled else { return }
        guard let answer else {
            loadPot = ServicePlaceholderCovers.seen.contains(url) ? "memo" : ""
            return
        }
        uiImage = answer.image
        loadPot = answer.pot
    }
}
