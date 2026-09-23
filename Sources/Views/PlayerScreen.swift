// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

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
            } else if coordinator.isLoading {
                ProgressView("Loading…")
            } else if let error = coordinator.loadError {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(coordinator.activeItem?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
