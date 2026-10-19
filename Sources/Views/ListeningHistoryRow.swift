// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE entry to a tab's listening history: one row at the end of the tab,
/// the same in the podcast, music and audiobook tabs. It pushes the tab's
/// own history route.
struct ListeningHistoryRow<Route: Hashable>: View {
    let route: Route
    let accessibilityId: String

    var body: some View {
        NavigationLink(value: route) {
            HStack {
                Label("Listening History", systemImage: ListenHistory.systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }
}
