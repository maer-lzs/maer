// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Global, transient glass pill (icon + short text) showing where the current
/// state comes from and how it is saved. Hosted ONCE centrally as an overlay in
/// the library's NavigationStack, so it appears on every level (library, book
/// detail, full player).
///
/// Its own view with `@ObservedObject` so changes to `sourceHint` arrive
/// reliably — a value read only via `coordinator.viewModel?.sourceHint` would
/// not update, since `PlayerCoordinator` only notifies when `viewModel` is
/// completely re-SET, not when values WITHIN it change (the same pattern as the
/// play/pause button).
struct ResumeMessageBanner: View {
    @ObservedObject var viewModel: PlayerViewModel

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Group {
            if let hint = viewModel.sourceHint {
                Label(hint.label, systemImage: hint.icon)
                    .font(.subheadline).bold()
                    .lineLimit(1)
                    // D9/B8: no fixedSize — the pill must never grow past the
                    // screen; long hints scale down instead of clipping.
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(AdaptiveGlassBackground(shape: shape))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    // Purely informational — must never intercept the sort menu,
                    // sign-out, search button, mini-player or player controls.
                    .allowsHitTesting(false)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.sourceHint)
    }
}
