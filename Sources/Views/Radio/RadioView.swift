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
    /// The ONE user-chosen state (persisted); nil = not chosen yet. Plain
    /// state + manual defaults I/O (an optional-String @AppStorage misbehaved
    /// in the harness bisect).
    @State private var chosenState: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionState)
    @State private var availableStates: [String] = []
    #if DEBUG
    @State private var seedRegionApplied = false
    #endif
    /// "Popular in Switzerland" — country name from the locale, localized.
    private var nationalTitle: String {
        guard let code = regionCode,
              let name = Locale.current.localizedString(forRegionCode: code) else {
            return String(localized: "Popular Stations")
        }
        return String(localized: "Popular in \(name)")
    }

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
                    // The radio library's prominent "card" (parity with the other
                    // tabs' continue/playlist cards): Recently Played as the
                    // reused RadioStationCard row, not a plain list. Favorites
                    // stays a list. Regel 2 — same card as "Most Played".
                    cardRow(title: String(localized: "Recently Played"), stations: recents)
                }
                if showsPopular {
                    cardRow(title: nationalTitle, stations: popular)
                }
                regionSection
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

    /// Regel 2: the row itself is the shared `RadioCardRow` (also on Home).
    private func cardRow(title: String, stations: [RadioStation]) -> some View {
        RadioCardRow(title: title, stations: stations,
                     playerCoordinator: playerCoordinator, onFavoriteToggled: reload)
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
        let favs = RadioStore.favorites()
        let recs = RadioStore.recents().filter { station in
            !favs.contains { $0.id == station.id }
        }
        let most = RadioStore.mostPlayed()
        // Layout-shift: same calm gate as loadDiscovery — the per-section
        // empty→filled rule applies to the library rows too (user-driven calls
        // run while calm, so they still apply instantly).
        BottomBarState.shared.runWhenCalm { [self] in
            favorites = favs
            recents = recs
            mostPlayed = most
        }
    }

    /// Fetch the catalog rows once per session (guarded), re-fetched on refresh.
    /// Net-gated: offline it does nothing and the sections stay hidden.
    /// Region = the user-chosen state: before the choice a small picker
    /// entry (never an empty list, never a second national section); a
    /// country without states hides the section silently.
    @ViewBuilder
    private var regionSection: some View {
        if let chosenState, !chosenState.isEmpty {
            if !regional.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    cardRow(title: chosenState, stations: regional)
                    Button {
                        self.chosenState = nil
                        UserDefaults.standard.removeObject(forKey: AppStorageKeys.radioRegionState)
                        regional = []
                        // Refill the picker list immediately — without this the
                        // section went DEAD until restart (confirmed regression).
                        Task { await loadDiscovery(force: true) }
                    } label: {
                        Text("Change region")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    // Locale-independent handle for the UI-test harness.
                    .accessibilityIdentifier("radio-region-change")
                }
            }
        } else if !availableStates.isEmpty, networkMonitor.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                Text("From Your Region").font(.title3).bold().padding(.horizontal)
                Menu {
                    ForEach(availableStates, id: \.self) { state in
                        Button(state) {
                            chosenState = state
                            UserDefaults.standard.set(state, forKey: AppStorageKeys.radioRegionState)
                            Task { await loadDiscovery(force: true) }
                        }
                    }
                } label: {
                    Label("Choose your region", systemImage: "mappin.and.ellipse")
                        .padding(.horizontal)
                }
                .accessibilityIdentifier("radio-region-picker")
            }
        }
    }

    private func loadDiscovery(force: Bool = false) async {
        guard networkMonitor.isConnected else { return }
        if !force, discoveryLoaded { return }
        #if DEBUG
        if UITestSeed.isActive {
            // Deterministic stand-in — no real Radio Browser call in the harness.
            popular = UITestSeed.seedRadioCatalog
            regional = UITestSeed.seedRadioCatalog
            // Seed region ONCE — after "Change region" the picker must win,
            // not an immediate re-choose by the seed branch.
            if chosenState == nil, !seedRegionApplied {
                chosenState = "Seed Region"
                seedRegionApplied = true
            }
            availableStates = ["Seed Region", "Seed Region Two"]   // picker testable
            discoveryLoaded = true
            return
        }
        #endif
        // National (the owner 26.07.): country top-votes instead of world —
        // less foreign-language noise; search covers the exotics.
        async let topTask = Self.nationalPopular(regionCode)
        async let regionTask = Self.stateStations(chosenState)
        let topResult = await topTask
        let regionResult = await regionTask
        RadioProvider.shared.remember(topResult + regionResult)   // resolvable for play
        // The state list of the device country (once per session) — a country
        // without states leaves the region section silently hidden.
        // Decoupled from chosenState (fixlet 4575a76): a returner with a
        // persisted state must still get the picker list when changing.
        if availableStates.isEmpty, let code = regionCode,
           let countryName = Locale(identifier: "en_US").localizedString(forRegionCode: code) {
            availableStates = (try? await RadioBrowserClient.states(countryName: countryName)) ?? []
        }
        // Layout-shift: the discovery sections land as whole-section inserts —
        // apply through the shared calm gate, never mid-scroll.
        BottomBarState.shared.runWhenCalm { [self] in
            popular = topResult
            regional = regionResult
        }
        discoveryLoaded = true
    }

    private static func nationalPopular(_ countryCode: String?) async -> [RadioStation] {
        guard let countryCode else {
            return (try? await RadioBrowserClient.popular()) ?? []   // no locale → world
        }
        return (try? await RadioBrowserClient.byRegion(countryCode: countryCode)) ?? []
    }

    /// The REAL region: stations of the user-chosen state (never guessed,
    /// never located — same choose-once pattern as the drive-mode BT device).
    private static func stateStations(_ state: String?) async -> [RadioStation] {
        guard let state, !state.isEmpty else { return [] }
        return (try? await RadioBrowserClient.byState(state: state)) ?? []
    }
}
