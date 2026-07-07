import SwiftUI

/// Ersatz für SwiftUIs `AsyncImage`, das einmal geladene Bilder cached und bei
/// einem Fehlversuch automatisch einmal nachlädt. Löst das "mal da, mal
/// nicht"-Problem, das AsyncImage in scrollbaren Grids/Listen zeigt.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
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
        if let cached = ImageCache.shared.image(for: url) {
            uiImage = cached
            return
        }
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
