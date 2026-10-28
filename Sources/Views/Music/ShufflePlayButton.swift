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
    /// songs, or a random library pool), with why it is empty when it is.
    let pool: () async -> ShufflePool


    @State private var busy = false
    /// The device's network, read the way the album page reads it.
    @Environment(\.isOnline) private var isOnline

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
            await Self.start(pool: pool, isOnline: isOnline, coordinator: playerCoordinator)
            busy = false
        }
    }

    /// Shuffles what the pool holds. An empty pool starts nothing and says
    /// why in the mini player, in the words of the album page: the list has
    /// no track, or the songs did not come, offline when the device has no
    /// network (as the album page decides it), else that they could not be
    /// loaded.
    static func start(pool: () async -> ShufflePool, isOnline: Bool, coordinator: PlayerCoordinator) async {
        let drawn = await pool()
        if case .songs(let items) = drawn {
            await coordinator.shufflePlay(items: items)
            return
        }
        guard !Task.isCancelled else { return }
        let (sentence, cause) = Self.sentence(for: drawn, isOnline: isOnline)
        coordinator.sayOpenFailure(sentence, cause: cause, title: nil)
    }

    /// The album page's title for each empty pool, with its symbol's cause.
    static func sentence(for pool: ShufflePool, isOnline: Bool) -> (String, NoticeCause) {
        switch pool {
        case .songs, .empty: (String(localized: "No tracks"), .unknown)
        case .unavailable where !isOnline: (String(localized: "Not available offline"), .network)
        case .unavailable: (String(localized: "Couldn't load tracks"), .server)
        }
    }
}
