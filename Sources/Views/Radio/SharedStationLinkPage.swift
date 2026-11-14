// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The page a station link opens when the catalog gave no station: a
/// catalog without an answer shows the failed load with Retry, a switched
/// off Radio Browser says so without Retry. Once the catalog answers with
/// the station, the page is the station's page.
struct SharedStationLinkPage: View {
    let uuid: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var lookUp: (String) async -> SharedLinkOpener.StationLookup = { await SharedLinkOpener.lookUpStation($0) }

    @State private var state: SharedLinkOpener.StationPageState
    @State private var isAsking = false

    init(uuid: String, gap: SharedLinkOpener.StationGap, playerCoordinator: PlayerCoordinator) {
        self.uuid = uuid
        self.playerCoordinator = playerCoordinator
        _state = State(initialValue: Self.state(of: gap))
    }

    /// The state the page opens in.
    nonisolated static func state(of gap: SharedLinkOpener.StationGap) -> SharedLinkOpener.StationPageState {
        switch gap {
        case .notLoaded: .notLoaded
        case .sourceOff: .sourceOff
        }
    }

    var body: some View {
        switch state {
        case .station(let station):
            RadioStationDetailView(station: station, playerCoordinator: playerCoordinator)
        case .notLoaded:
            LoadFailedView(form: .page(title: Text("Radio"), systemImage: "dot.radiowaves.left.and.right")) {
                Task { await askAgain() }
            }
        case .sourceOff:
            EmptyStateView(title: Text("Radio"), systemImage: "dot.radiowaves.left.and.right",
                           description: Text(SharedLinkOpener.stationSourceOff)) { EmptyView() }
        case .unknown:
            EmptyStateView(title: Text("Radio"), systemImage: "dot.radiowaves.left.and.right",
                           description: Text(SharedLinkOpener.refusal)) { EmptyView() }
        }
    }

    private func askAgain() async {
        guard !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        state = SharedLinkOpener.pageState(uuid: uuid, lookup: await lookUp(uuid))
    }
}
