import SwiftUI

/// Value-based navigation for the podcast area. Pushes go into the library's
/// `navigationPath`, so the media-tab tap (which empties that path) pops back to
/// the library root. Plain `NavigationLink { destination }` pushes are NOT in the
/// path and would stay put — that was the "media bar doesn't return to library"
/// bug on podcast pages.
enum PodcastRoute: Hashable {
    case show(feedURL: String)
    case episode(itemId: String)
    case queue
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
            case .queue:
                PodcastQueueView(playerCoordinator: playerCoordinator)
            }
        }
    }
}
