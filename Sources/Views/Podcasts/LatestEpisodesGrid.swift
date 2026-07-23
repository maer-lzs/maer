// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    // Front 2 fix 2: NO grid-level store observing — a download progress tick
    // used to re-render all ~30 tiles on TWO mounted tabs. Availability is
    // resolved per tile by the shared MediaAvailabilityScope (TF4/E1 pattern).
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
            // Front 2 fix 1 (trace-backed): NO standing `.animation(value:)` on
            // the grid — it made every tile frame an animatable attribute on
            // TWO permanently mounted tabs (86k AnimatableFrameAttribute
            // updates in a 9 s scroll trace). The toggle is the ONLY flip site,
            // so a withAnimation transaction there gives the identical curve in
            // both directions (Y45's goal) without the per-frame tracking.
            // Curve unchanged: Y62 `.easeInOut(0.35)` (no overshoot on collapse).
            if items.count > cols * 2 {
                Button {
                    withAnimation(.easeInOut(duration: 0.35)) { expanded.toggle() }
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
        MediaAvailabilityScope(itemId: item.id) { unavailable in
            MediaTile(
                title: item.title,
                coverURL: AppSession.shared.coverURL(forItemId: item.id),
                cornerBadgeURL: showBadgeURL(for: item),
                progress: episodeProgress(item),
                unavailable: unavailable,
                onTap: { pushRoute(.episode(itemId: item.id)) }
            ) {
                MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
            }
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
