// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Value-based navigation for the podcast area. Pushes go into the library's
/// `navigationPath`, so the media-tab tap (which empties that path) pops back to
/// the library root. Plain `NavigationLink { destination }` pushes are NOT in the
/// path and would stay put — that was the "media bar doesn't return to library"
/// bug on podcast pages.
enum PodcastRoute: Hashable {
    case show(feedURL: String)
    case episode(itemId: String)
    /// Y2b: the temporary show preview for a not-yet-subscribed show.
    case showPreview(feedURL: String)
    /// V6: the chronological listen history (PodcastListenLog).
    case history
    /// e96d396 B2: the premium shows' full page (Blaupause "Zuletzt
    /// hinzugefuegt": heading -> full grid). The S22 management surface is NOT
    /// this page — this one browses, management stays where it is.
    case premium
    /// Welle 3: the continue row's full page (HOEREN grid — tap plays).
    case nextUpAll
    /// Welle 3: the full recommendation pool — Home's Discover chevron and
    /// the podcast tab's Recommended chevron land on the SAME page (Regel 2).
    case recommendations
    /// Welle 3b: full pages behind the expanding rows (DIE REGEL: an
    /// expansion is not a page).
    case latestAll
    case downloadsAll
    /// J2: the full subscription grid behind the "Recently Updated" preview.
    case subscriptions
    /// Pinchflat Paket B: the mirrored group's full channel grid.
    case pinchflatGroup
    /// X²·5: the book-category charts (1482) as a full grid — measured: no
    /// carrying sub-division, so no shelf tier.
    case bookCharts
    /// H (7749411): the two-stage chart form — charts page (genres as tile
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
                    ContentUnavailableView("Show unavailable", systemImage: "mic")
                }
            case .episode(let itemId):
                if let item = AppSession.shared.libraryItem(forId: itemId) {
                    PodcastEpisodeDetailView(item: item, playerCoordinator: playerCoordinator)
                } else {
                    ContentUnavailableView("Episode unavailable", systemImage: "mic")
                }
            case .showPreview(let feedURL):
                PodcastShowPreviewView(feedURL: feedURL)
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
            case .bookCharts:
                BookChartsPage()
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

/// Push callback for podcast routes — buttons deep inside List rows use this
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
/// LibraryView) — Home tiles push through this so book taps land in the
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
