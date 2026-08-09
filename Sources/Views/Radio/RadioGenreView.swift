// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// F4-discovery: the stations of one curated genre — the Radio Browser
/// `bytagexact` list, as shared `RadioStationRow`s. Net-gated like the browse
/// sections: offline it shows the offline state instead of an empty page.
struct RadioGenreView: View {
    let tag: String
    let title: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var stations: [RadioStation] = []
    @State private var loading = false
    @State private var loadedTag: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !networkMonitor.isConnected {
                    offlineState
                } else if loading && stations.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                        .padding()
                } else if stations.isEmpty {
                    ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                        .padding(.top, 40)
                } else {
                    ForEach(stations) { station in
                        RadioStationRow(station: station, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: tag) { await load() }
        .refreshable { await load(force: true) }
    }

    private var offlineState: some View {
        ContentUnavailableView("Offline", systemImage: "wifi.slash",
                               description: Text("Browsing the radio catalog needs a connection."))
            .padding(.top, 40)
    }

    private func load(force: Bool = false) async {
        guard networkMonitor.isConnected else { return }
        // Session cache: don't re-fetch the same tag on every appearance.
        if !force, loadedTag == tag, !stations.isEmpty { return }
        loading = true
        defer { loading = false }
        #if DEBUG
        if UITestSeed.isActive {
            stations = UITestSeed.seedRadioCatalog   // no real network in the harness
            loadedTag = tag
            return
        }
        #endif
        let result = (try? await RadioBrowserClient.byTag(tag: tag)) ?? []
        RadioProvider.shared.remember(result)   // keep them resolvable for play
        stations = result
        loadedTag = tag
    }
}
