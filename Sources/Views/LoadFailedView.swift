// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What a surface shows when its fetch failed (`FetchAnswer.failed`): the
/// sentence and a way to ask again. A failed load is not "no results": the
/// empty text stays for an answer that was empty. Three forms, one wording:
/// a whole page (the content-unavailable form with the page's title and
/// glyph), a line below the rows already read, and a row of a list section,
/// which takes the look of the section's empty text beside it ("No
/// playlists yet."), so the two states of one card read alike.
struct LoadFailedView: View {
    enum Form {
        case page(title: Text, systemImage: String)
        case line
        case row
    }

    let form: Form
    var sentence: LocalizedStringKey = "This could not be loaded. Check your connection."
    let retry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// At an accessibility size a row puts "Retry" under its sentence: beside
    /// it the sentence wrapped into a narrow column (five lines in the
    /// podcast search at AX3).
    nonisolated static func rowStacks(accessibilitySize: Bool) -> Bool { accessibilitySize }

    var body: some View {
        switch form {
        case .page(let title, let systemImage):
            ContentUnavailableView {
                Label { title } icon: { Image(systemName: systemImage) }
            } description: {
                Text(sentence)
            } actions: {
                retryPill
            }
        case .line:
            HStack(spacing: 10) {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                retryPill
            }
            .frame(maxWidth: .infinity)
        case .row:
            if Self.rowStacks(accessibilitySize: typeSize.isAccessibilitySize) {
                VStack(alignment: .leading, spacing: 6) {
                    rowSentence
                    rowRetry
                }
            } else {
                HStack(spacing: 10) {
                    rowSentence
                    rowRetry
                }
            }
        }
    }

    private var rowSentence: some View {
        Text(sentence)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowRetry: some View { retryPill }

    /// "Retry" as a pill: the card pills' `PillLabel`, in the accent on a
    /// light tint, because those pills are white on a coloured card and
    /// would vanish on a list.
    private var retryPill: some View {
        Button(action: retry) {
            PillLabel(systemImage: "arrow.clockwise", title: Text("Retry"),
                      foreground: AppTheme.accent, fill: Color.primary.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("load-failed-retry")
    }
}
