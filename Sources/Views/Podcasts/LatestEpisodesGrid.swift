import SwiftUI

/// X1c (Regel 2): THE latest-episodes grid — identical on Home and the
/// podcast tab. Two rows collapsed / up to six expanded (inline, not
/// persisted), columns adaptive by width (iPhone 3, small iPad 4, large
/// iPad 5). Tiles are the shared `MediaTile` with the show cover as the
/// ~24 pt corner badge ONLY when the episode ships its own artwork (nothing
/// doubled), the play corner badge, progress bar, episode context menu and
/// the A3 unavailable treatment. Self-measuring — callers pass items only.
struct LatestEpisodesGrid: View {
    /// Newest-episode-per-show items (see `PodcastSections.newestPerShow`).
    let items: [LibraryItem]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushPodcastRoute) private var pushRoute
    /// A3: connectivity/download flips must re-render the badge state.
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    /// Y3a: 2 rows collapsed, up to 6 expanded — inline, not persisted.
    @State private var expanded = false
    @State private var width: CGFloat = 0

    private var columns: Int {
        guard width > 0 else { return 3 }
        if width >= 1000 { return 5 }
        if width >= 640 { return 4 }
        return 3
    }

    var body: some View {
        let cols = columns
        let rows = expanded ? 6 : 2
        let shown = Array(items.prefix(cols * rows))
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest Episodes").font(.title3).bold().padding(.horizontal)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                alignment: .leading, spacing: 14
            ) {
                ForEach(shown) { item in
                    episodeTile(item)
                }
            }
            .padding(.horizontal)
            // Y45: bind the animation to `expanded` on the grid itself (not a
            // withAnimation wrapper around the toggle) so the row add/remove
            // runs with the SAME curve in BOTH directions. Y55: 0.35 — a touch
            // slower. Y62 (candidate): a plain timing curve instead of the
            // `.snappy` spring — the spring overshot on COLLAPSE, so the content
            // below rushed up too fast. `.easeInOut` settles without overshoot;
            // decelerating out. Feel is the owner'ss call in the device loop.
            .animation(.easeInOut(duration: 0.35), value: expanded)
            if items.count > cols * 2 {
                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? String(localized: "Show Less")
                                   : String(localized: "Show More"),
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        )
    }

    private func episodeTile(_ item: LibraryItem) -> some View {
        MediaTile(
            title: item.title,
            coverURL: AppSession.shared.coverURL(forItemId: item.id),
            cornerBadgeURL: showBadgeURL(for: item),
            progress: episodeProgress(item),
            unavailable: !networkMonitor.isConnected && !downloadManager.isDownloaded(itemId: item.id),
            onTap: { pushRoute(.episode(itemId: item.id)) }
        ) {
            MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
        }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
    }

    /// The show cover as a corner badge only when the tile image is the
    /// episode's OWN artwork (feed-provided) — never double the show cover.
    private func showBadgeURL(for item: LibraryItem) -> URL? {
        guard let show = AppSession.shared.rssProvider.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw),
              url != AppSession.shared.coverURL(forItemId: item.id)
        else { return nil }
        return url
    }

    private func episodeProgress(_ item: LibraryItem) -> Double? {
        if case .inProgress(let fraction, _) = podcastPlayState(for: item) { return fraction }
        return nil
    }
}
