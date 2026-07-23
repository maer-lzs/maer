// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// F4: THE radio station row — shared by the favorites/recents lists and the
/// genre drilldown (Regel 2). Plays directly (F3: play replaces the active
/// playback, never queued); favorite toggles from the context menu. Offline the
/// row dims and carries the white status glyph, and the tap is disabled.
struct RadioStationRow: View {
    let station: RadioStation
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Called after the favorite is toggled, so a favorites list can refresh.
    var onFavoriteToggled: () -> Void = {}
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            MediaRowContent(
                coverURL: nil,
                eyebrow: station.tags.first,
                title: station.name,
                titleDimmed: !networkMonitor.isConnected,
                coverDimmed: !networkMonitor.isConnected,
                offlineBadge: !networkMonitor.isConnected,
                placeholderSystemImage: "dot.radiowaves.left.and.right",
                coverOverride: AnyView(RadioArtwork(
                    stationID: station.id,
                    faviconURL: station.faviconURL.flatMap { URL(string: $0) }))
            )
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!networkMonitor.isConnected)
        .contextMenu {
            RadioFavoriteButton(station: station, onToggled: onFavoriteToggled)
            RadioDetailsButton(station: station, push: pushRadioRoute)
        }
    }
}

/// F4-discovery: a station as a compact card for the horizontal browse rows
/// (Popular / From your region) — the shared `RadioArtwork` (Y58) over the name.
struct RadioStationCard: View {
    let station: RadioStation
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var onFavoriteToggled: () -> Void = {}
    @Environment(\.pushRadioRoute) private var pushRadioRoute

    static let width: CGFloat = 128

    var body: some View {
        Button {
            RadioPlay.play(station, playerCoordinator: playerCoordinator)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) })
                    .frame(width: Self.width, height: Self.width)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(station.name)
                    .font(.caption.weight(.medium))
                    // Layout-shift/a11y: reserve both lines at the CURRENT type
                    // size — the fixed 34 pt matched two caption lines only at
                    // the default size (clipped at accessibility sizes, uneven
                    // card heights otherwise).
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: Self.width, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            RadioFavoriteButton(station: station, onToggled: onFavoriteToggled)
            RadioDetailsButton(station: station, push: pushRadioRoute)
        }
    }
}

/// Teil 1: context-menu entry that opens the station detail page (tap still
/// plays directly — F3). Shared by the row and the card.
struct RadioDetailsButton: View {
    let station: RadioStation
    let push: @MainActor (RadioRoute) -> Void

    var body: some View {
        Button {
            push(.station(station))
        } label: {
            Label("Station Details", systemImage: "info.circle")
        }
    }
}

/// Shared add/remove-favorite menu button.
struct RadioFavoriteButton: View {
    let station: RadioStation
    var onToggled: () -> Void = {}

    var body: some View {
        Button {
            RadioStore.toggleFavorite(station)
            onToggled()
        } label: {
            Label(RadioStore.isFavorite(station.id) ? String(localized: "Remove Favorite")
                                                     : String(localized: "Add Favorite"),
                  systemImage: RadioStore.isFavorite(station.id) ? "star.slash" : "star")
        }
    }
}

enum RadioPlay {
    /// The recent-ring records centrally in `RadioProvider.fetchItemDetail`.
    @MainActor
    static func play(_ station: RadioStation, playerCoordinator: PlayerCoordinator) {
        RadioProvider.shared.remember([station])   // keep catalog hits resolvable
        Task { await playerCoordinator.open(item: RadioProvider.libraryItem(for: station)) }
    }
}

/// The shared horizontal station-card row (title + RadioStationCard carousel) —
/// used by the radio tab's sections AND the Home "Radio" section (Regel 2: one
/// row component, no copies).
struct RadioCardRow: View {
    let title: String
    let stations: [RadioStation]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var onFavoriteToggled: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(stations) { station in
                        RadioStationCard(station: station, playerCoordinator: playerCoordinator,
                                         onFavoriteToggled: onFavoriteToggled)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
