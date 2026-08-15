// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// F4-discovery: value-based radio routes, registered on the library's
/// NavigationStack root (like `PodcastRoute`/`MusicRoute`) so a media-tab tap
/// pops the drilldown back to the tab (the X15 lesson: a plain destination link
/// would stay on the stack).
enum RadioRoute: Hashable {
    /// Stations for a curated genre (Radio Browser tag) — the byTag list.
    case genre(tag: String, title: String)
    /// Teil 1: a station's detail page (info + codec/bitrate variant picker).
    case station(RadioStation)
    /// The full page behind a counted browse row (Regel 2: one parameterised
    /// page, the row passes its whole stock).
    case stationList(title: String, stations: [RadioStation])
}

/// Teil 1: push a RadioRoute from a non-link surface (a context-menu button) —
/// set on the NavigationStack itself by LibraryView, like `pushMusicRoute`, so
/// pushed views inherit it and a tap that also plays can still open the detail.
nonisolated struct PushRadioRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (RadioRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushRadioRoute: @MainActor (RadioRoute) -> Void {
        get { self[PushRadioRouteKey.self] }
        set { self[PushRadioRouteKey.self] = newValue }
    }
}

extension View {
    func radioNavigationDestinations(playerCoordinator: PlayerCoordinator) -> some View {
        navigationDestination(for: RadioRoute.self) { route in
            switch route {
            case .genre(let tag, let title):
                RadioGenreView(tag: tag, title: title, playerCoordinator: playerCoordinator)
            case .station(let station):
                RadioStationDetailView(station: station, playerCoordinator: playerCoordinator)
            case .stationList(let title, let stations):
                RadioStationListPage(title: title, stations: stations,
                                     playerCoordinator: playerCoordinator)
            }
        }
    }
}
