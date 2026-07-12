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
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else { return }
        if useThumbnail {
            let thumb = thumbnailMaxPixel != nil
                ? await ImageCache.shared.thumbnail(for: url, maxPixelSize: thumbnailMaxPixel!)
                : await ImageCache.shared.thumbnail(for: url)
            if let thumb { uiImage = thumb; return }
        }
        if !useThumbnail, let cached = ImageCache.shared.image(for: url) {
            uiImage = cached
            return
        }
        // Thumbnail miss = cover not on disk yet: fall through to the
        // network fetch (fills the disk cache; next display uses the thumb).
        if let image = await fetch(url, retryDelay: nil) {
            uiImage = image
            return
        }
        // Ein automatischer zweiter Versuch nach kurzer Pause — deckt die
        // meisten kurzen Netzwerk-Aussetzer/Server-Hakler ab, ohne dass der
        // Nutzer manuell etwas tun muss.
        if let image = await fetch(url, retryDelay: 800_000_000) {
            uiImage = image
        }
    }

    private func fetch(_ url: URL, retryDelay: UInt64?) async -> UIImage? {
        if let retryDelay {
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        ImageCache.shared.set(image, data: data, for: url)
        return image
    }
}
