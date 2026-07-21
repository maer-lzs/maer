// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// F4: the radio tab. On top, the user's own stations (favorites + last-heard
/// rows). Below, the catalog browse layer (F4-discovery): Popular, From your
/// region, and curated genres — all net-gated, so offline the tab falls back to
/// the cached favorites/recents and nothing breaks. Stations play directly
/// (F3: play replaces the active playback, never queued).
struct RadioView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    // User's own stations (UserDefaults-backed store).
    @State private var favorites: [RadioStation] = []
    @State private var recents: [RadioStation] = []
    // Teil 3: stations ranked by play frequency (net-independent — from the store).
    @State private var mostPlayed: [RadioStation] = []
    // Catalog browse — cached per session, re-fetched only on refresh.
    @State private var popular: [RadioStation] = []
    @State private var regional: [RadioStation] = []
    @State private var discoveryLoaded = false
    private let regionCode = RadioCatalog.deviceRegionCode()

    private var showsPopular: Bool { RadioCatalog.showsPopular(isConnected: networkMonitor.isConnected, popular: popular) }
    private var showsRegion: Bool { RadioCatalog.showsRegion(isConnected: networkMonitor.isConnected, regionCode: regionCode, regional: regional) }
    private var showsGenres: Bool { RadioCatalog.showsGenres(isConnected: networkMonitor.isConnected) }
    private var hasAnyContent: Bool {
        !mostPlayed.isEmpty || !favorites.isEmpty || !recents.isEmpty || showsPopular || showsRegion || showsGenres
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                if !mostPlayed.isEmpty {
                    cardRow(title: String(localized: "Most Played"), stations: mostPlayed)
                }
                if !favorites.isEmpty {
                    listSection(title: String(localized: "Favorites"), stations: favorites)
                }
                if !recents.isEmpty {
                    listSection(title: String(localized: "Recently Played"), stations: recents)
                }
                if showsPopular {
                    cardRow(title: String(localized: "Popular Stations"), stations: popular)
                }
                if showsRegion {
                    cardRow(title: String(localized: "From Your Region"), stations: regional)
                }
                if showsGenres {
                    genreSection
                }
                if !hasAnyContent {
                    if networkMonitor.isConnected && !discoveryLoaded {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        emptyState
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .reportsBottomBarScroll(active: isActive)
        .topEdgeFade()   // GT3c: fade anchored to this tab's scroll viewport
        .refreshable { await loadDiscovery(force: true) }
        .task(id: "\(isActive)-\(playerCoordinator.activeItem?.id ?? "")") {
            reload()
            await loadDiscovery()
        }
    }

    // MARK: - Sections

    private func listSection(title: String, stations: [RadioStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(stations) { station in
                    RadioStationRow(station: station, playerCoordinator: playerCoordinator,
                                    onFavoriteToggled: reload)
                    Divider().padding(.leading, 88)
                }
            }
        }
    }

    private func cardRow(title: String, stations: [RadioStation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(stations) { station in
                        RadioStationCard(station: station, playerCoordinator: playerCoordinator,
                                         onFavoriteToggled: reload)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Genre").font(.title3).bold().padding(.horizontal)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(RadioCatalog.genres) { genre in
                    NavigationLink(value: RadioRoute.genre(tag: genre.tag, title: genre.title)) {
                        HStack(spacing: 12) {
                            Image(systemName: genre.systemImage)
                                .font(.title2)
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 28)
                            Text(genre.title).font(.body.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("radio-genre-\(genre.tag)")
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No stations yet", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Search the catalog with the magnifier and star your stations — or add a stream URL under Settings → Sources → Radio.")
        }
        .padding(.top, 60)
    }

    // MARK: - Loading

    private func reload() {
        favorites = RadioStore.favorites()
        recents = RadioStore.recents().filter { station in
            !favorites.contains { $0.id == station.id }
        }
        mostPlayed = RadioStore.mostPlayed()
    }

    /// Fetch the catalog rows once per session (guarded), re-fetched on refresh.
    /// Net-gated: offline it does nothing and the sections stay hidden.
    private func loadDiscovery(force: Bool = false) async {
        guard networkMonitor.isConnected else { return }
        if !force, discoveryLoaded { return }
        #if DEBUG
        if UITestSeed.isActive {
            // Deterministic stand-in — no real Radio Browser call in the harness.
            popular = UITestSeed.seedRadioCatalog
            regional = UITestSeed.seedRadioCatalog
            discoveryLoaded = true
            return
        }
        #endif
        async let topTask = RadioBrowserClient.popular()
        async let regionTask = Self.regionStations(regionCode)
        let topResult = (try? await topTask) ?? []
        let regionResult = await regionTask
        RadioProvider.shared.remember(topResult + regionResult)   // resolvable for play
        popular = topResult
        regional = regionResult
        discoveryLoaded = true
    }

    private static func regionStations(_ countryCode: String?) async -> [RadioStation] {
        guard let countryCode else { return [] }
        return (try? await RadioBrowserClient.byRegion(countryCode: countryCode)) ?? []
    }
}
