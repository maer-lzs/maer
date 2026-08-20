// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// cb2d1ed: the page behind "My Stations" — the two sources divided apart
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
                        Text("Star a station, or listen to one — it will show up here.")
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

    /// A station that is starred belongs to the FAVORITES section only — the
    /// page divides, it does not show the same card twice.
    private var withoutFavorites: [RadioStation] {
        let starred = Set(favorites.map(\.id))
        return mostPlayed.filter { !starred.contains($0.id) }
    }

    private func section(_ title: String, stations: [RadioStation], starred: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(stations) { station in
                        RadioFeaturedCard(station: station,
                                          playerCoordinator: playerCoordinator,
                                          isFavorite: starred,
                                          listenedSeconds: seconds[station.id] ?? 0)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
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
