// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// F4-discovery: the stations of one curated genre, as shared
/// `RadioStationRow`s. Net-gated like the browse sections: offline it shows
/// the offline state instead of an empty page.
///
/// eb10440: the list is narrowed to the CHOSEN COUNTRIES. Without a narrowing
/// the global vote ranking answers with whatever the world votes for, which
/// on this device reads as junk. The default is the environment (the existing
/// cascade), the choice holds for ALL genre pages, and worldwide stays
/// reachable as a deliberate option.
struct RadioGenreView: View {
    let tag: String
    let title: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var stations: [RadioStation] = []
    @State private var loading = false
    @State private var loadedKey: String?
    @State private var loadFailed = false
    @State private var showCountryPicker = false
    /// e77e0b1: the OBSERVED shared selection — never a private copy. A
    /// `@State` snapshot read at init was two truths, and the visible list
    /// missed changes until restart on the device.
    @ObservedObject private var selection = RadioGenreCountrySelection.shared

    private var cascadeCode: String? {
        RadioCountryCascade.effectiveCode(
            explicit: UserDefaults.standard.string(forKey: AppStorageKeys.radioChosenCountryCode),
            regionImplied: UserDefaults.standard.string(forKey: AppStorageKeys.radioRegionCountryCode),
            locale: RadioCatalog.deviceRegionCode())
    }

    private var effectiveCodes: [String] {
        RadioGenreCountries.effectiveCodes(stored: selection.stored, cascade: cascadeCode)
    }

    private var isWorldwide: Bool { effectiveCodes.isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                countryBar
                if !networkMonitor.isConnected {
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
                    ForEach(stations) { station in
                        RadioStationRow(station: station, playerCoordinator: playerCoordinator)
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
        }
    }

    /// The countries this page is showing, plus the way to change them — the
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

    /// G8: too few stations is shown, never hidden — with the one way out
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

    /// The selection is persistent and shared by ALL genre pages — not per
    /// genre. Writing happens only on a real choice, so an untouched install
    /// keeps following the cascade.
    private func store(_ codes: [String]) {
        selection.store(codes)
    }

    private func load(force: Bool = false) async {
        guard networkMonitor.isConnected else { return }
        let key = RadioGenreCountries.loadKey(tag: tag, codes: effectiveCodes)
        // Session cache: don't re-fetch the same page on every appearance —
        // keyed on tag AND selection, or a country change shows the old list.
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
        } catch is CancellationError {
            // ebda0fa (GT R6b): a CANCELLED run is not a failure — fifth
            // instance of the throw-is-not-the-end class. Switching the
            // selection restarts `.task(id:)`, which cancels the run in
            // flight; booking that as `loadFailed` showed "check your
            // connection" on an intact network. The restarted task loads the
            // real answer a moment later.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadFailed = true
            return
        }
        let result = RadioGenreCuration.page(union, deviceLanguage: Locale.current.language.languageCode?.identifier)
        RadioProvider.shared.remember(result)   // keep them resolvable for play
        // Same rule as the browse rows: the logos are resolved from HERE, with
        // the data in hand — a genre page is exactly where stations appear that
        // nobody ever played, and those never got a stored result before.
        let list = result.map { (id: $0.id, name: $0.name, homepage: $0.homepage) }
        Task { await RadioLogoService.shared.warm(list) }
        stations = result
        loadedKey = key
    }
}
