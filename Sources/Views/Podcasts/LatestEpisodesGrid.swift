// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE latest-episodes grid. Identical on Home and the
/// podcast tab. Two rows collapsed / up to six expanded (inline, not
/// persisted), columns adaptive by width (iPhone 3, small iPad 4, large
/// iPad 5). Tiles are the shared `MediaTile` with the show cover as the
/// ~24 pt corner badge ONLY when the episode ships its own artwork (nothing
/// doubled), the play corner badge, progress bar, episode context menu and
/// the offline-unavailable treatment. Self-measuring. Callers pass items only.
struct LatestEpisodesGrid: View {
    @Environment(\.itemRouter) private var router
    /// Newest-episode-per-show items (see `PodcastSections.newestPerShow`).
    let items: [LibraryItem]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.pushPodcastRoute) private var pushRoute
    /// Connectivity/download flips must re-render the badge state.
    // NO grid-level store observing. A download progress tick used to
    // re-render all ~30 tiles on TWO mounted tabs. Availability is resolved
    // per tile by the shared MediaAvailabilityScope.
    /// The full page reuses THIS grid without the row cap. One grid, two
    /// cuts.
    var alwaysExpanded = false
    /// The row "Co-listened" is this grid under another heading and without
    /// a page: the same tile, the same capsule, the same menu.
    var title: LocalizedStringKey = "Latest Episodes"
    var destination: PodcastRoute? = .latestAll
    var showMoreId = "episodes-show-more"
    /// 2 rows collapsed, up to 6 expanded. Inline, not persisted.
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
        // Membership resolved ONCE per render (cell-cost rule),
        // handed to the tiles as a value.
        let mirrored = PodcastSubscriptions.shared.mirroredEpisodeGuids()
        // Co-listened shows, resolved ONCE per render like the others; the
        // tile says "not subscribed" and the menu offers the subscription.
        let coListened = CoListenedShows.current()
        // Same cell-cost rule: the premium classification is a
        // keychain/defaults lookup. Resolved ONCE per render for the shown
        // episodes, handed to the tiles as a value. Starts "Latest Episodes"
        // was the one episode surface without the lock (measured). A lasting
        // refusal of the feed turns the lock into the warning, as on the
        // show tiles.
        let subs = PodcastSubscriptions.shared
        let feeds = shown.compactMap { item in subs.feedURL(forEpisodeId: item.id).map { (id: item.id, feed: $0) } }
        let premiumEpisodes = Set(feeds.filter { PodcastSubscriptions.isPremiumFeed($0.feed) }.map(\.id))
        let refusedEpisodes = Set(feeds.filter { subs.isAccessRefused(feedURL: $0.feed) }.map(\.id))
        VStack(alignment: .leading, spacing: 10) {
            if !alwaysExpanded {
                // The heading carries the page chevron (counted.
                // The expansion is a preview, the page is the stock).
                RowHeading(title: title,
                           total: items.count, shown: shown.count,
                           destination: destination)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                alignment: .leading, spacing: 14
            ) {
                ForEach(shown) { item in
                    episodeTile(item, mirrored: mirrored,
                                isPremium: premiumEpisodes.contains(item.id),
                                isRefused: refusedEpisodes.contains(item.id),
                                coListened: CoListenedShows.feedKey(forEpisodeId: item.id, among: coListened)
                                    .flatMap { key in coListened.first { $0.feedKey == key } })
                }
            }
            .padding(.horizontal)
            // Measured in a trace: NO standing `.animation(value:)` on
            // the grid. It made every tile frame an animatable attribute on
            // TWO permanently mounted tabs (86k AnimatableFrameAttribute
            // updates in a 9 s scroll trace). The toggle is the ONLY flip site,
            // so a withAnimation transaction there gives the identical curve in
            // both directions without the per-frame tracking.
            // Curve `.easeInOut(0.35)` (no overshoot on collapse).
            // The anatomy now lives in `ShowMoreRow`. The
            // trace finding above is preserved there, not restated here.
            if !alwaysExpanded {
                ShowMoreRow(expanded: $expanded, hasMore: items.count > cols * 2,
                            accessibilityId: showMoreId)
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
                             isPremium: Bool, isRefused: Bool, coListened: CoListened.Show? = nil) -> some View {
        MediaAvailabilityScope(itemId: item.id) { unavailable in
            MediaTile(
                title: item.title,
                coverURL: router.coverURL(item.id),
                cornerBadgeURL: showBadgeURL(for: item),
                // The tile anchors the lock itself. On the cover, not
                // over the title text (where the outer modifier put it).
                isPremium: isPremium,
                isRefused: isRefused,
                progress: episodeProgress(item),
                unavailable: unavailable,
                // Origin capsule for mirrored episodes (host-computed
                // set, word is the carrier).
                badgeText: mirrored.contains(item.id) ? "YouTube"
                    : (coListened != nil ? String(localized: "Not subscribed") : nil),
                badgeSystemImage: mirrored.contains(item.id) ? "play.rectangle"
                    : (coListened != nil ? "plus.circle" : nil),
                onTap: { pushRoute(.episode(itemId: item.id)) }
            ) {
                MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
            }
        }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator, coListened: coListened)
    }

    /// The show cover as a corner badge only when the tile image is the
    /// episode's OWN artwork (feed-provided). Never double the show cover.
    private func showBadgeURL(for item: LibraryItem) -> URL? {
        guard let show = PodcastShowSources.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw),
              url != router.coverURL(item.id)
        else { return nil }
        return url
    }

    private func episodeProgress(_ item: LibraryItem) -> Double? {
        if case .inProgress(let fraction, _) = podcastPlayState(for: item) { return fraction }
        return nil
    }
}
