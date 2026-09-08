// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// F4-discovery: the stations of one curated genre, as shared
/// `RadioStationRow`s. Net-gated like the browse sections: offline it shows
/// the offline state instead of an empty page.
///
/// The list is narrowed to the CHOSEN COUNTRIES. Without a narrowing
/// the global vote ranking answers with whatever the world votes for, which
/// on this device reads as junk. The default is the environment (the existing
/// cascade), the choice holds for ALL genre pages, and worldwide stays
/// reachable as a deliberate option.
struct RadioGenreView: View {
    let tag: String
    let title: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.isOnline) private var isOnline

    @State private var stations: [RadioStation] = []
    @State private var loading = false
    @State private var loadedKey: String?
    @State private var loadFailed = false
    @State private var showCountryPicker = false
    /// The OBSERVED shared selection. Never a private copy. A
    /// `@State` snapshot read at init was two truths, and the visible list
    /// missed changes until restart on the device.
    @ObservedObject private var selection = RadioGenreCountrySelection.shared

    private var cascadeCode: String? {
        RadioCountryCascade.effectiveCode(
            explicit: AppStorageKeys.string(AppStorageKeys.radioChosenCountryCode),
            regionImplied: AppStorageKeys.string(AppStorageKeys.radioRegionCountryCode),
            locale: RadioCatalog.deviceRegionCode())
    }

    private var effectiveCodes: [String] {
        RadioGenreCountries.effectiveCodes(stored: selection.stored, cascade: cascadeCode)
    }

    private var isWorldwide: Bool { effectiveCodes.isEmpty }

    /// Which collapsed families are open. Per page visit, not
    /// persisted (an expansion is a glance, not a setting).
    @State private var expandedFamilies: Set<String> = []

    private func expandedFamilyBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedFamilies.contains(id) },
                set: { open in
                    if open { expandedFamilies.insert(id) }
                    else { expandedFamilies.remove(id) }
                })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                countryBar
                if !isOnline {
                    offlineState
                } else if loading && stations.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        .padding()
                } else if loadFailed {
                    // Rule 3: a failed load is not "no stations".
                    ContentUnavailableView {
                        Label(title, systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("This could not be loaded. Check your connection.")
                    } actions: {
                        Button("Retry") { Task { await load(force: true) } }
                    }
                    .padding(.top, 40)
                } else if stations.isEmpty {
                    ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                        .padding(.top, 40)
                    worldwideOffer
                } else {
                    // Family collapse. A DISPLAY rule of
                    // THIS list only. Same domain + explicit name head fold
                    // to one entry (Konferenz or best-voted in front); the
                    // variants expand in place via the existing ShowMoreRow
                    // form with the honest count. Search, favorites, My
                    // Stations and Recents keep showing single channels.
                    ForEach(RadioGenreFamilies.collapsed(stations)) { family in
                        RadioStationRow(station: family.front, playerCoordinator: playerCoordinator)
                        if !family.variants.isEmpty {
                            ShowMoreRow(
                                expanded: expandedFamilyBinding(family.id),
                                hasMore: true,
                                accessibilityId: "radio-family-toggle",
                                moreLabel: String(localized: "\(family.count) channels"))
                                .padding(.leading, 72)
                                .padding(.vertical, 6)
                            if expandedFamilies.contains(family.id) {
                                ForEach(family.variants) { station in
                                    RadioStationRow(station: station,
                                                    playerCoordinator: playerCoordinator)
                                }
                            }
                        }
                        Divider().padding(.leading, 88)
                    }
                    worldwideOffer
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: RadioGenreCountries.loadKey(tag: tag, codes: effectiveCodes)) { await load() }
        .refreshable { await load(force: true) }
        .sheet(isPresented: $showCountryPicker) {
            NavigationStack {
                RadioCountryPickerList(
                    onChoose: { _, _ in },
                    selection: Set(effectiveCodes),
                    onToggle: { code in
                        store(RadioGenreCountries.toggled(code, in: effectiveCodes))
                    },
                    onWorldwide: { store([]) })
            }
            .followsAppearanceChoice()
        }
    }

    /// The countries this page is showing, plus the way to change them. The
    /// same mechanic and the same wording as the "Change Country" link under
    /// the popular row.
    private var countryBar: some View {
        HStack {
            Text(countryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                showCountryPicker = true
            } label: {
                Text("Change Countries").font(.caption)
            }
            .accessibilityIdentifier("radio-genre-countries-change")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var countryLabel: String {
        guard !isWorldwide else { return String(localized: "Worldwide") }
        let names = effectiveCodes.map {
            Locale.current.localizedString(forRegionCode: $0) ?? $0
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    /// Too few stations is shown, never hidden. With the one way out
    /// that exists. Worldwide itself has no wider fallback.
    @ViewBuilder
    private var worldwideOffer: some View {
        if !loading,
           RadioGenreCuration.offersWorldwide(count: stations.count, isWorldwide: isWorldwide) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Few stations for this genre in the selected countries.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Show worldwide") { store([]) }
                    .font(.footnote)
                    .accessibilityIdentifier("radio-genre-show-worldwide")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var offlineState: some View {
        ContentUnavailableView("Offline", systemImage: "wifi.slash",
                               description: Text("Browsing the radio catalog needs a connection."))
            .padding(.top, 40)
    }

    /// The selection is persistent and shared by ALL genre pages. Not per
    /// genre. Writing happens only on a real choice, so an untouched install
    /// keeps following the cascade.
    private func store(_ codes: [String]) {
        selection.store(codes)
    }

    private func load(force: Bool = false) async {
        guard isOnline else { return }
        let key = RadioGenreCountries.loadKey(tag: tag, codes: effectiveCodes)
        // Session cache: don't re-fetch the same page on every appearance.
        // Keyed on tag AND selection, or a country change shows the old list.
        if !force, loadedKey == key, !stations.isEmpty { return }
        loading = true
        defer { loading = false }
        #if DEBUG
        if UITestSeed.isActive {
            stations = UITestSeed.seedRadioCatalog   // no real network in the harness
            loadedKey = key
            loadFailed = false
            return
        }
        #endif
        let union: [RadioStation]
        do {
            union = try await RadioBrowserClient.byTag(tag: tag, countryCodes: effectiveCodes)
            loadFailed = false
        } catch {
            // A CANCELLED run is not a failure. The shared
            // rule (`isCancellation`), asked before anything is booked.
            guard !error.isCancellation else { return }
            loadFailed = true
            return
        }
        let deviceLanguage = Locale.current.language.languageCode?.identifier
        var result = RadioGenreCuration.page(union, deviceLanguage: deviceLanguage)
        // The worldwide SPOKEN page carries the curated world-services
        // core; votes cannot (the spread between the services is three
        // orders of magnitude, so a vote sort buries all but one below
        // the fetch limit). Resolved by name like the national cores;
        // music pages stay untouched, their worldwide axis is a named
        // open decision.
        if effectiveCodes.isEmpty, RadioGenreCuration.spokenGenreTags.contains(tag) {
            let core = await Self.resolveWorldCore(pool: union)
            result = RadioGenreCuration.withWorldCore(result, core: core,
                                                      deviceLanguage: deviceLanguage)
        }
        RadioProvider.shared.remember(result)   // keep them resolvable for play
        // Same rule as the browse rows: the logos are resolved from HERE, with
        // the data in hand. A genre page is exactly where stations appear that
        // nobody ever played, and those never got a stored result before.
        let list = result.map { (id: $0.id, name: $0.name, homepage: $0.homepage) }
        Task { await RadioLogoService.shared.warm(list) }
        stations = result
        loadedKey = key
    }

    /// Resolve the world-services core against the fetched pool; names
    /// the pool does not carry get a BOUNDED number of targeted lookups.
    /// The same mechanism as the national cores, without a country: the
    /// misses go to the log, never silent. Resolved stations bypass the
    /// vote floor on purpose; the list IS the decision to show them.
    private static func resolveWorldCore(pool: [RadioStation]) async -> [RadioStation] {
        let core = RadioWorldServices.services
        var resolution = RadioCoreResolve.resolve(core: core, pool: pool, countryCode: nil)
        var lookedUp: [RadioStation] = []
        for missName in resolution.misses.prefix(6) {
            for query in RadioCoreResolve.lookupQueries(missName, countryCode: nil).prefix(3) {
                guard let found = try? await RadioBrowserClient.search(name: query, limit: 10)
                else { continue }
                let probe = RadioCoreResolve.resolve(core: [missName], pool: found,
                                                     countryCode: nil)
                if !probe.stations.isEmpty {
                    lookedUp += found
                    break
                }
            }
        }
        if !lookedUp.isEmpty {
            resolution = RadioCoreResolve.resolve(core: core, pool: pool + lookedUp,
                                                  countryCode: nil)
        }
        // The renames are the runtime twin of the generator's run report:
        // a wrong seizure (the name-alike class) shows up HERE, because a
        // wrongly resolved name is no miss and never reaches the lookup.
        let renames = resolution.mapping.map { "\($0.core)→\($0.matched)" }.joined(separator: " · ")
        Logger.library.notice("RADIO world core resolved=\(resolution.stations.count)/\(core.count) misses=\(resolution.misses.joined(separator: " · "), privacy: .public) renames=\(renames, privacy: .public)")
        return resolution.stations
    }
}
