// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// Welle 3b: the full page reuses THIS grid without the row cap —
    /// Regel 2, one grid, two cuts.
    var alwaysExpanded = false
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
        // items.count instead of Int.max: cols * rows must not overflow.
        let rows = alwaysExpanded ? max(items.count, 1) : (expanded ? 6 : 2)
        let shown = Array(items.prefix(cols * rows))
        // Paket B: membership resolved ONCE per render (cell-cost rule),
        // handed to the tiles as a value.
        let mirrored = PodcastSubscriptions.shared.mirroredEpisodeGuids()
        // P13 (same cell-cost rule): the premium classification is a
        // keychain/defaults lookup — resolved ONCE per render for the shown
        // episodes, handed to the tiles as a value. Starts "Latest Episodes"
        // was the one episode surface without the lock (measured).
        let premiumEpisodes = Set(shown.compactMap { item -> String? in
            guard let feed = PodcastSubscriptions.shared.feedURL(forEpisodeId: item.id),
                  PodcastSubscriptions.isPremiumFeed(feed) else { return nil }
            return item.id
        })
        VStack(alignment: .leading, spacing: 10) {
            if !alwaysExpanded {
                // Welle 3b: the heading carries the page chevron (counted —
                // the expansion is a preview, the page is the stock).
                RowHeading(title: "Latest Episodes",
                           total: items.count, shown: shown.count,
                           destination: PodcastRoute.latestAll)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                alignment: .leading, spacing: 14
            ) {
                ForEach(shown) { item in
                    episodeTile(item, mirrored: mirrored,
                                isPremium: premiumEpisodes.contains(item.id))
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
            // P11: the anatomy now lives in `ShowMoreRow` (Regel 2) — the
            // trace finding above is preserved there, not restated here.
            if !alwaysExpanded {
                ShowMoreRow(expanded: $expanded, hasMore: items.count > cols * 2,
                            accessibilityId: "episodes-show-more")
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

    private func episodeTile(_ item: LibraryItem, mirrored: Set<String>,
                             isPremium: Bool) -> some View {
        MediaAvailabilityScope(itemId: item.id) { unavailable in
            MediaTile(
                title: item.title,
                coverURL: AppSession.shared.coverURL(forItemId: item.id),
                cornerBadgeURL: showBadgeURL(for: item),
                progress: episodeProgress(item),
                unavailable: unavailable,
                // Paket B: origin capsule for mirrored episodes (host-computed
                // set, word is the carrier — a916a5a).
                badgeText: mirrored.contains(item.id) ? "YouTube" : nil,
                badgeSystemImage: mirrored.contains(item.id) ? "play.rectangle" : nil,
                onTap: { pushRoute(.episode(itemId: item.id)) }
            ) {
                MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
            }
            .premiumLock(isPremium)
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
