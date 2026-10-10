// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Global, transient glass pill (icon + short text) showing where the current
/// state comes from and how it is saved. Two hosts: above the mini bar in the
/// library, on every level of its stack (`LibraryView`), and in the full
/// player, in the space its controls leave free (`FullPlayerOverlay`).
///
/// Its own view observing the one channel (`PlaybackNotices`), so a notice
/// arrives without any other redraw; what shows, and for how long, the
/// channel decides.
struct ResumeMessageBanner: View {
    @ObservedObject var notices: PlaybackNotices
    @State private var showsLog = false

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
                    // A tap opens the log. The pill takes exactly its own
                    // capsule, nothing beside or under it: the sort menu,
                    // sign-out, search, the mini player and the player
                    // controls keep every touch outside it. Reading the
                    // log does not end a stopping error; the next start does.
                    .contentShape(shape)
                    .onTapGesture { showsLog = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Shows all notices"))
                    .accessibilityIdentifier("notice-pill")
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: notices.shown)
        // On the container, which stays when the pill goes after its time,
        // so the log stays open.
        .sheet(isPresented: $showsLog) {
            // A settings page outside the settings sheet: its stack sets the
            // row style like the sheet does.
            NavigationStack { NoticeLogView(notices: notices) }
                .labelStyle(RowLabelStyle())
                .followsAppearanceChoice()
        }
    }
}
