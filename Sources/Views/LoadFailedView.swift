// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What a surface shows when its fetch failed (`FetchAnswer.failed`): the
/// sentence and a way to ask again. A failed load is not "no results": the
/// empty text stays for an answer that was empty. Two forms, one wording:
/// a whole page (the content-unavailable form with the page's title and
/// glyph) and a line inside a list or below the rows already read.
struct LoadFailedView: View {
    enum Form {
        case page(title: Text, systemImage: String)
        case line
    }

    let form: Form
    var sentence: LocalizedStringKey = "This could not be loaded. Check your connection."
    let retry: () -> Void

    var body: some View {
        switch form {
        case .page(let title, let systemImage):
            ContentUnavailableView {
                Label { title } icon: { Image(systemName: systemImage) }
            } description: {
                Text(sentence)
            } actions: {
                Button("Retry", action: retry)
                    .accessibilityIdentifier("load-failed-retry")
            }
        case .line:
            HStack(spacing: 10) {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry", action: retry)
                    .font(.footnote)
                    .accessibilityIdentifier("load-failed-retry")
            }
            .frame(maxWidth: .infinity)
        }
    }
}
