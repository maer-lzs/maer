// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The ONE shuffle-play entry point (Regel 2): the music-tab root (whole
/// library), a playlist detail and an album detail all use this same button —
/// only the `pool` closure differs (each supplies its own item set). The shared
/// `PlayerCoordinator.shufflePlay` orders them with the pure `MediaShuffle`.
struct ShufflePlayButton: View {
    enum Style { case prominent, icon, menuItem }

    @ObservedObject var playerCoordinator: PlayerCoordinator
    var style: Style = .prominent
    /// Supplies the items to shuffle (loaded lazily on tap — an album/playlist's
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
            let items = await pool()
            await playerCoordinator.shufflePlay(items: items)
            busy = false
        }
    }
}
