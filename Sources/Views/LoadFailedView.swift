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
    let sentence: Text
    let retry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    init(form: Form, sentence: LocalizedStringKey = "This could not be loaded. Check your connection.",
         retry: @escaping () -> Void) {
        self.init(form: form, sentence: Text(sentence), retry: retry)
    }

    /// A sentence that exists only at run time: a server's reason, the
    /// message of a failed load, a search's own words.
    init(form: Form, sentence: Text, retry: @escaping () -> Void) {
        self.form = form
        self.sentence = sentence
        self.retry = retry
    }

    /// At an accessibility size a row puts "Retry" under its sentence: beside
    /// it the sentence wrapped into a narrow column (five lines in the
    /// podcast search at AX3).
    nonisolated static func rowStacks(accessibilitySize: Bool) -> Bool { accessibilitySize }

    var body: some View {
        switch form {
        case .page(let title, let systemImage):
            EmptyStateView(title: title, systemImage: systemImage, description: sentence) {
                retryPill
            }
        case .line:
            HStack(spacing: 10) {
                sentence
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
        sentence
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowRetry: some View { retryPill }

    private var retryPill: some View { RetryPill(action: retry) }
}

/// "Retry" as a pill: the card pills' `PillLabel`, in the accent on a light
/// tint, because those pills are white on a coloured card and would vanish
/// on a list. `LoadFailedView` draws it in all three forms; a surface with a
/// sentence of its own (the search's drill page) draws it directly and keeps
/// its own identifier.
struct RetryPill: View {
    var identifier = "load-failed-retry"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillLabel(systemImage: "arrow.clockwise", title: Text("Retry"),
                      foreground: AppTheme.accent, fill: Color.primary.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
