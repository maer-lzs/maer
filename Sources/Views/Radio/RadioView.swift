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
    private let localeCode = RadioCatalog.deviceRegionCode()
    /// The ONE user-chosen state (persisted); nil = not chosen yet. Plain
    /// state + manual defaults I/O (an optional-String @AppStorage misbehaved
    /// in the harness bisect).
    @State private var chosenState: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionState)
    /// Curated picker list (b942da6): merged variants, noise filtered,
    /// sorted by station count.
    @State private var availableStates: [RadioBrowseCuration.Curated] = []
    @State private var showRegionPicker = false
    /// b1ab99d cascade: explicit country choice (a) and the country implied
    /// by the chosen region (b); locale stays the last fallback (c).
    @State private var chosenCountryCode: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioChosenCountryCode)
    @State private var chosenCountryName: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioChosenCountryName)
    @State private var impliedCountryCode: String? = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionCountryCode)
    #if DEBUG
    @State private var seedRegionApplied = false
    #endif

    /// USER CHOICE BEATS GUESSING (b1ab99d): the ONE country code feeding
    /// "Popular in …" and the region list.
    private var effectiveCountryCode: String? {
        RadioCountryCascade.effectiveCode(explicit: chosenCountryCode,
                                          regionImplied: impliedCountryCode,
                                          locale: localeCode)
    }

    /// English country name for the Radio Browser states path.
    private var effectiveCountryName: String? {
        if let chosenCountryName, !chosenCountryName.isEmpty { return chosenCountryName }
        if let implied = UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionCountryName),
           !implied.isEmpty { return implied }
        guard let code = effectiveCountryCode else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    /// "Popular in Switzerland" — follows the country cascade, localized.
    private var nationalTitle: String {
        guard let code = effectiveCountryCode,
              let name = Locale.current.localizedString(forRegionCode: code) else {
            return String(localized: "Popular Stations")
        }
        return String(localized: "Popular in \(name)")
    }

    private var showsPopular: Bool { RadioCatalog.showsPopular(isConnected: networkMonitor.isConnected, popular: popular) }
    private var showsRegion: Bool { RadioCatalog.showsRegion(isConnected: networkMonitor.isConnected, regionCode: effectiveCountryCode, regional: regional) }
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
        // b1ab99d: region picker as a sheet (search field + country layer).
        .sheet(isPresented: $showRegionPicker) {
            RadioRegionPickerSheet(states: availableStates,
                                   countryTitle: nationalCountryDisplayName,
                                   onChooseRegion: chooseRegion,
                                   onChooseCountry: chooseCountry)
        }
    }

    /// Localized display name of the effective country (sheet subtitle).
    private var nationalCountryDisplayName: String? {
        effectiveCountryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
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
                        UserDefaults.standard.removeObject(forKey: AppStorageKeys.radioRegionQueryNames)
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
                // b1ab99d: the picker is a SHEET now — a Menu cannot carry the
                // required search field or the country layer.
                Button {
                    showRegionPicker = true
                } label: {
                    Label("Choose your region", systemImage: "mappin.and.ellipse")
                        .padding(.horizontal)
                }
                .accessibilityIdentifier("radio-region-picker")
            }
        }
    }

    /// Region choice: persist display name + ALL merged raw names (the query
    /// runs against every variant) + the implied country (cascade step b).
    private func chooseRegion(_ entry: RadioBrowseCuration.Curated) {
        chosenState = entry.display
        UserDefaults.standard.set(entry.display, forKey: AppStorageKeys.radioRegionState)
        UserDefaults.standard.set(entry.queryNames, forKey: AppStorageKeys.radioRegionQueryNames)
        if let code = effectiveCountryCode {
            impliedCountryCode = code
            UserDefaults.standard.set(code, forKey: AppStorageKeys.radioRegionCountryCode)
        }
        if let name = effectiveCountryName {
            UserDefaults.standard.set(name, forKey: AppStorageKeys.radioRegionCountryName)
        }
        showRegionPicker = false
        Task { await loadDiscovery(force: true) }
    }

    /// Explicit country choice (cascade step a): persists, clears the old
    /// country's region choice and refills the picker list.
    private func chooseCountry(code: String, name: String) {
        chosenCountryCode = code
        chosenCountryName = name
        UserDefaults.standard.set(code, forKey: AppStorageKeys.radioChosenCountryCode)
        UserDefaults.standard.set(name, forKey: AppStorageKeys.radioChosenCountryName)
        // The old country's region makes no sense anymore.
        chosenState = nil
        impliedCountryCode = nil
        for key in [AppStorageKeys.radioRegionState, AppStorageKeys.radioRegionQueryNames,
                    AppStorageKeys.radioRegionCountryCode, AppStorageKeys.radioRegionCountryName] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        regional = []
        availableStates = []
        Task { await loadDiscovery(force: true) }
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
            availableStates = [
                RadioBrowseCuration.Curated(display: "Seed Region", queryNames: ["Seed Region"], stationCount: 3),
                RadioBrowseCuration.Curated(display: "Seed Region Two", queryNames: ["Seed Region Two"], stationCount: 2),
            ]   // picker testable
            discoveryLoaded = true
            return
        }
        #endif
        // National (the owner 26.07.): country top-votes instead of world —
        // less foreign-language noise; search covers the exotics. b1ab99d:
        // the country follows the cascade (choice beats guess).
        async let topTask = Self.nationalPopular(effectiveCountryCode)
        async let regionTask = Self.stateStations(chosenState)
        let topResult = await topTask
        let regionResult = await regionTask
        RadioProvider.shared.remember(topResult + regionResult)   // resolvable for play
        // The state list of the effective country (once per session) — a
        // country without states leaves the region section silently hidden.
        // Decoupled from chosenState (fixlet 4575a76): a returner with a
        // persisted state must still get the picker list when changing.
        // b942da6: raw entries run through the pure curation (merge/filter/sort).
        if availableStates.isEmpty, let countryName = effectiveCountryName {
            let raw = (try? await RadioBrowserClient.states(countryName: countryName)) ?? []
            availableStates = RadioBrowseCuration.curated(raw)
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
    /// b942da6: the query runs against ALL merged name variants (persisted at
    /// choice time) — otherwise the other spelling's stations vanish; results
    /// dedupe by station id, first (best-voted of the winner name) stays.
    private static func stateStations(_ state: String?) async -> [RadioStation] {
        guard let state, !state.isEmpty else { return [] }
        let names = (UserDefaults.standard.array(forKey: AppStorageKeys.radioRegionQueryNames) as? [String])
            .flatMap { $0.isEmpty ? nil : $0 } ?? [state]
        var seen = Set<String>()
        var merged: [RadioStation] = []
        for name in names {
            let batch = (try? await RadioBrowserClient.byState(state: name)) ?? []
            for station in batch where seen.insert(station.id).inserted {
                merged.append(station)
            }
        }
        return merged
    }
}
