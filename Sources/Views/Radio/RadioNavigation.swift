import SwiftUI

/// F4-discovery: value-based radio routes, registered on the library's
/// NavigationStack root (like `PodcastRoute`/`MusicRoute`) so a media-tab tap
/// pops the drilldown back to the tab (the X15 lesson: a plain destination link
/// would stay on the stack).
enum RadioRoute: Hashable {
    /// Stations for a curated genre (Radio Browser tag) — the byTag list.
    case genre(tag: String, title: String)
}

extension View {
    func radioNavigationDestinations(playerCoordinator: PlayerCoordinator) -> some View {
        navigationDestination(for: RadioRoute.self) { route in
            switch route {
            case .genre(let tag, let title):
                RadioGenreView(tag: tag, title: title, playerCoordinator: playerCoordinator)
            }
        }
    }
}
