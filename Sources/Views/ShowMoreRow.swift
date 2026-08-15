// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// P11 (Regel 2): THE inline expander line under a preview grid — the Y3a
/// anatomy from `LatestEpisodesGrid`, lifted out so the audiobook stock uses
/// the same one instead of a second version.
///
/// Two ways, deliberately side by side (same logic as the capsule rows): the
/// heading chevron leads to the FULL page, this line shows more IN PLACE.
///
/// **G8:** the line only exists when there is actually more than what is
/// shown — with a small stock it disappears instead of promising a "more"
/// that is not there. The caller decides that with `hasMore`, because only it
/// knows how its grid counts (a series stack counts its members).
struct ShowMoreRow: View {
    @Binding var expanded: Bool
    let hasMore: Bool
    var accessibilityId: String = "show-more-row"

    var body: some View {
        if hasMore {
            Button {
                // The toggle is the ONLY flip site — a withAnimation
                // transaction here gives the same curve in both directions
                // WITHOUT making every tile frame an animatable attribute
                // (the Front-2 trace finding, kept intact by this move).
                withAnimation(.easeInOut(duration: 0.35)) { expanded.toggle() }
            } label: {
                Label(expanded ? String(localized: "Show Less")
                               : String(localized: "Show More"),
                      systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal)
            .accessibilityIdentifier(accessibilityId)
        }
    }
}
