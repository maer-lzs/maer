// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The page behind "My Stations". The two sources divided apart
/// again. The row merges them because it answers ONE question ("mine"); here
/// there is room to say which is which, and no neighbouring row, so the
/// recently played station reappears instead of being left out.
struct RadioMyStationsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator

    @State private var favorites: [RadioStation] = []
    @State private var mostPlayed: [RadioStation] = []
    @State private var seconds: [String: Int] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // Same build form as the row (the preview rule): a full page
                // that showed a different shape would read as another place.
                if !favorites.isEmpty {
                    section(String(localized: "Favorites"), stations: favorites, starred: true)
                }
                if !withoutFavorites.isEmpty {
                    section(String(localized: "Most Played"), stations: withoutFavorites, starred: false)
                }
                if favorites.isEmpty, withoutFavorites.isEmpty {
                    ContentUnavailableView {
                        Label("No stations yet", systemImage: "star")
                    } description: {
                        Text("Star a station, or listen to one. It will show up here.")
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("My Stations"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    /// A station that is starred belongs to the FAVORITES section only. The
    /// page divides, it does not show the same card twice.
    private var withoutFavorites: [RadioStation] {
        let starred = Set(favorites.map(\.id))
        return mostPlayed.filter { !starred.contains($0.id) }
    }

    private func section(_ title: String, stations: [RadioStation], starred: Bool) -> some View {
        // TILE rows, not cards. Two sections of
        // screen-filling cards are no overview. The cards stay reserved for
        // the tab's row; this page is the dividing-apart. Same build form and
        // metric as the browse rows, same tile behaviour (tap navigates,
        // ▶ plays), star on the favorite tiles.
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(stations) { station in
                        RadioStationCard(station: station,
                                         playerCoordinator: playerCoordinator,
                                         isFavorite: starred)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func reload() {
        seconds = ListeningStatsStore.shared.radioSeconds()
        favorites = RadioMyStations.composed(
            favorites: RadioStore.favorites(), mostPlayed: [],
            seconds: seconds, excluding: nil, limit: .max)
        mostPlayed = RadioStore.mostPlayed(limit: 24, seconds: seconds)
    }
}
