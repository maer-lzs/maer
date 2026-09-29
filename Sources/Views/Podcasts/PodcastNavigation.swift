// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Value-based navigation for the podcast area. Pushes go into the library's
/// `navigationPath`, so the media-tab tap (which empties that path) pops back to
/// the library root. Plain `NavigationLink { destination }` pushes are NOT in the
/// path and would stay put. That was the "media bar doesn't return to library"
/// bug on podcast pages.
enum PodcastRoute: Hashable {
    /// THE show page, for a subscribed show and for one that is only being
    /// looked at. The page resolves the state itself, so a feed reached from
    /// search or a recommendation lands on the same surface as one from the
    /// subscription grid.
    case show(feedURL: String)
    case episode(itemId: String)
    /// The chronological listen history (PodcastListenLog).
    case history
    /// The premium shows' full page (built like "Recently Added": heading ->
    /// full grid). The premium management surface is NOT this page. This one browses, management stays where it is.
    case premium
    /// Welle 3: the continue row's full page (HOEREN grid. Tap plays).
    case nextUpAll
    /// Welle 3: the full recommendation pool. Home's Discover chevron and
    /// the podcast tab's Recommended chevron land on the SAME page.
    case recommendations
    /// Full pages behind the expanding rows (an expansion is not a page).
    case latestAll
    case downloadsAll
    /// The full subscription grid behind the "Recently Updated" preview.
    case subscriptions
    /// The mirrored group's full channel grid.
    case pinchflatGroup
    /// X²·5: the book-category charts (1482) as a full grid. Measured: no

    /// H: the two-stage chart form. Charts page (genres as tile
    /// rows) and one parameterised genre page (full grid).
    case charts
    case chartGenre(String)
}

extension View {
    /// Registers the podcast destinations on the enclosing NavigationStack.
    /// Attach once on the podcast tab root; it stays active for deeper pushes
    /// (show → episode) because that root stays mounted beneath them.
    func podcastNavigationDestinations(playerCoordinator: PlayerCoordinator) -> some View {
        navigationDestination(for: PodcastRoute.self) { route in
            switch route {
            case .show(let feedURL):
                if let show = PodcastAutoContinue.show(forFeedURL: feedURL) {
                    PodcastShowView(show: show, playerCoordinator: playerCoordinator)
                } else {
                    PodcastShowView(feedURL: feedURL, playerCoordinator: playerCoordinator)
                }
            case .episode(let itemId):
                PodcastEpisodeDestination(itemId: itemId, playerCoordinator: playerCoordinator)
            case .premium:
                PremiumShowsPage(playerCoordinator: playerCoordinator)
            case .nextUpAll:
                PodcastContinuePage(playerCoordinator: playerCoordinator)
            case .recommendations:
                RecommendationsPage()
            case .latestAll:
                LatestEpisodesPage(playerCoordinator: playerCoordinator)
            case .downloadsAll:
                PodcastDownloadsPage(playerCoordinator: playerCoordinator)
            case .subscriptions:
                PodcastSubscriptionsPage(playerCoordinator: playerCoordinator)
            case .pinchflatGroup:
                PinchflatGroupPage(playerCoordinator: playerCoordinator)
            case .charts:
                RadioPlayChartsPage()
            case .chartGenre(let key):
                ChartGenrePage(chipKey: key)
            case .history:
                PodcastHistoryView(playerCoordinator: playerCoordinator)
            }
        }
    }
}

/// Push callback for podcast routes. Buttons deep inside List rows use this
/// instead of NavigationLink: a link inside row content makes List draw a
/// disclosure chevron on the whole row.
nonisolated struct PushPodcastRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (PodcastRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushPodcastRoute: @MainActor (PodcastRoute) -> Void {
        get { self[PushPodcastRouteKey.self] }
        set { self[PushPodcastRouteKey.self] = newValue }
    }
}

/// Push callback for a BOOK detail page (String route registered in
/// LibraryView). Home tiles push through this so book taps land in the
/// library's `navigationPath` like every other value route.
nonisolated struct PushBookDetailKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushBookDetail: @MainActor (String) -> Void {
        get { self[PushBookDetailKey.self] }
        set { self[PushBookDetailKey.self] = newValue }
    }
}

/// The episode page behind a route. A view of its own so the item is asked
/// of the router in the environment, which a destination closure cannot read.
struct PodcastEpisodeDestination: View {
    @Environment(\.itemRouter) private var router
    let itemId: String
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        if let item = router.item(itemId) {
            PodcastEpisodeDetailView(item: item, playerCoordinator: playerCoordinator)
        } else {
            ContentUnavailableView("Episode unavailable", systemImage: "mic")
        }
    }
}
