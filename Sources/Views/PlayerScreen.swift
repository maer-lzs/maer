// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What the full player shows, pure. A spinner only while something IS
/// loading. With no session, no load and no error there is nothing to show:
/// the mirror cleared a finished title (`STANDBY cleared live`) or the
/// advance found nothing, and the player used to spin forever over it.
nonisolated enum PlayerScreenContent: Equatable {
    case player
    case loading
    case error(String)
    case nothing

    static func of(hasSession: Bool, isLoading: Bool, loadError: String?) -> PlayerScreenContent {
        if hasSession { return .player }
        if isLoading { return .loading }
        if let loadError { return .error(loadError) }
        return .nothing
    }
}

/// Shows the session currently running in the PlayerCoordinator as the full
/// player screen. Loads nothing itself anymore. The coordinator handles
/// loading so the same session stays visible from the mini-player bar too.
struct PlayerScreen: View {
    @Environment(\.itemRouter) private var router
    @ObservedObject var coordinator: PlayerCoordinator
    /// Passed through from the overlay presentation (drag-to-dismiss).
    var dragProgress: CGFloat = 0
    /// Corner radius of the overlay sheet. Passed through to PlayerView.
    var cornerRadius: CGFloat = 0
    /// Explizite Safe-Area-Insets (Root ignoriert Safe Areas).
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    var body: some View {
        Group {
            if let viewModel = coordinator.viewModel, let item = coordinator.activeItem {
                PlayerView(
                    viewModel: viewModel,
                    coordinator: coordinator,
                    coverURL: router.coverURL(item.id),
                    dragProgress: dragProgress,
                    cornerRadius: cornerRadius,
                    topInset: topInset,
                    bottomInset: bottomInset
                )
            } else {
                switch coordinator.screenContent {
                case .loading:
                    ProgressView("Loading…")
                case .error(let error):
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                    }
                    .padding()
                case .nothing, .player:
                    // Said for the moment the overlay needs to close itself.
                    // `.player` never lands here: the branch above has it.
                    Text("Nothing is playing.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("player-nothing-playing")
                }
            }
        }
        .navigationTitle(coordinator.activeItem?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension PlayerCoordinator {
    /// The full player's content, asked by the screen and by the overlay
    /// that closes itself on `.nothing`.
    var screenContent: PlayerScreenContent {
        PlayerScreenContent.of(hasSession: viewModel != nil && activeItem != nil,
                               isLoading: isLoading, loadError: loadError)
    }
}
