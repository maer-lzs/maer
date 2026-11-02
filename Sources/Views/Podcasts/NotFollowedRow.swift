// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// One feed in "Not followed yet": the masked address, why it could not be
/// followed, the one way that can help, and dismissing it here. Its own
/// component so the large-text cell draws the real row.
struct NotFollowedRow: View {
    let feedKey: String
    let entry: FeedAdoptionPending.Entry
    let onNewLink: () -> Void
    let onSignIn: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Side by side, the button squeezed the reason into a column of
        // syllables at the large sizes (measured on an AX3 cell), so there
        // the actions go below the text. Chosen by the size, not by trying.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    texts
                    HStack(spacing: 12) {
                        action
                        Spacer(minLength: 0)
                        dismiss
                    }
                }
            } else {
                HStack(spacing: 12) {
                    texts
                    Spacer(minLength: 0)
                    action
                    dismiss
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Never the address unmasked (token feeds carry secrets).
            Text(PodcastIdentity.maskedFeedURL(entry.feedURL))
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Could not be followed: \(FeedAdoptionPending.phrase(entry.reason, status: entry.status))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        if entry.reason == .accessRefused {
            Button("Enter new link", action: onNewLink)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast-newlink-\(feedKey)")
        } else if entry.reason == .signIn {
            Button("Sign in", action: onSignIn)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast-signin-\(feedKey)")
        } else {
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("podcast-retry-\(feedKey)")
        }
    }

    private var dismiss: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Dismiss"))
        .accessibilityIdentifier("podcast-signin-remove-\(feedKey)")
    }
}
