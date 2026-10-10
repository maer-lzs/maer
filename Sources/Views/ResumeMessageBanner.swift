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
/// Its own view observing the one channel (`PlaybackNotices`), so a notice
/// arrives without any other redraw; what shows, and for how long, the
/// channel decides.
struct ResumeMessageBanner: View {
    @ObservedObject var notices: PlaybackNotices

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Group {
            if let hint = notices.shown {
                Label(hint.label, systemImage: hint.icon)
                    .font(.subheadline).bold()
                    .lineLimit(1)
                    // No fixedSize. The pill must never grow past the
                    // screen; long hints scale down instead of clipping.
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .modifier(AdaptiveGlassBackground(shape: shape))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    // Purely informational. Must never intercept the sort menu,
                    // sign-out, search button, mini-player or player controls.
                    .allowsHitTesting(false)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: notices.shown)
    }
}
