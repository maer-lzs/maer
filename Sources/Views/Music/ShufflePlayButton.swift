// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ONE shuffle-play entry point: the music-tab root (whole
/// library), a playlist detail and an album detail all use this same button.
/// Only the `pool` closure differs (each supplies its own item set). The shared
/// `PlayerCoordinator.shufflePlay` orders them with the pure `MediaShuffle`.
struct ShufflePlayButton: View {
    enum Style { case prominent, icon, menuItem }

    @ObservedObject var playerCoordinator: PlayerCoordinator
    var style: Style = .prominent
    /// Supplies the items to shuffle (loaded lazily on tap. An album/playlist's
    /// songs, or a random library pool).
    let pool: () async -> [LibraryItem]

    @State private var busy = false

    var body: some View {
        switch style {
        case .prominent:
            Button(action: trigger) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("shuffle-play")
        case .icon:
            Button(action: trigger) {
                Image(systemName: "shuffle")
            }
            .disabled(busy)
            .accessibilityIdentifier("shuffle-play")
        case .menuItem:
            // The SAME action as a long-press menu entry (consistency slot).
            Button(action: trigger) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(busy)
        }
    }

    private func trigger() {
        guard !busy else { return }
        busy = true
        Task {
            await Self.start(pool: pool, coordinator: playerCoordinator)
            busy = false
        }
    }

    /// Shuffles what the pool holds. An empty pool (a server that did not
    /// answer, a list without songs) starts nothing and says so in the mini
    /// player, never a tap that does nothing.
    static func start(pool: () async -> [LibraryItem], coordinator: PlayerCoordinator) async {
        let items = await pool()
        guard !items.isEmpty else {
            guard !Task.isCancelled else { return }
            coordinator.sayOpenFailure(String(localized: "Couldn't load tracks"), cause: .unknown, title: nil)
            return
        }
        await coordinator.shufflePlay(items: items)
    }
}
