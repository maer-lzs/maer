import SwiftUI

/// F4: the radio tab — favorites and last-heard stations as shared rows;
/// the CATALOG lives in the global search (radio scope). Stations play
/// directly (F3: play replaces the active playback, never queued). Offline
/// everything dims WITH the white status glyph (A3 rule) — a live stream
/// without network is simply unavailable.
struct RadioView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    /// Re-render on favorite/recent changes (UserDefaults-backed store).
    @State private var favorites: [RadioStation] = []
    @State private var recents: [RadioStation] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                if favorites.isEmpty && recents.isEmpty {
                    emptyState
                } else {
                    if !favorites.isEmpty {
                        section(title: String(localized: "Favorites"), stations: favorites)
                    }
                    if !recents.isEmpty {
                        section(title: String(localized: "Recently Played"), stations: recents)
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .reportsBottomBarScroll(active: isActive)
        .task(id: "\(isActive)-\(playerCoordinator.activeItem?.id ?? "")") {
            reload()
        }
    }

    private func reload() {
        favorites = RadioStore.favorites()
        recents = RadioStore.recents().filter { station in
            !favorites.contains { $0.id == station.id }
        }
    }

    private func section(title: String, stations: [RadioStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(stations) { station in
                    stationRow(station)
                    Divider().padding(.leading, 88)
                }
            }
        }
    }

    private func stationRow(_ station: RadioStation) -> some View {
        Button {
            play(station)
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
            Button {
                RadioStore.toggleFavorite(station)
                reload()
            } label: {
                Label(RadioStore.isFavorite(station.id) ? String(localized: "Remove Favorite")
                                                        : String(localized: "Add Favorite"),
                      systemImage: RadioStore.isFavorite(station.id) ? "star.slash" : "star")
            }
        }
    }

    private func play(_ station: RadioStation) {
        // The recent-ring records centrally in RadioProvider.fetchItemDetail.
        Task { await playerCoordinator.open(item: RadioProvider.libraryItem(for: station)) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No stations yet", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Search the catalog with the magnifier and star your stations — or add a stream URL under Settings → Sources → Radio.")
        }
        .padding(.top, 60)
    }
}
