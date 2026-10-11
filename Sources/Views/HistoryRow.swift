// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// One row of a listening history: the title, below it the show, author or
/// artist and how long ago. A title that never arrived says so instead of
/// showing an empty line; a missing second line and a date that cannot be
/// true are left out rather than drawn as "· 56 years ago". The history of
/// the episodes and the history of books and songs show this one row.
struct HistoryRow: View {
    let title: String
    let subtitle: String
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.isEmpty ? String(localized: "Title unknown") : title)
                .font(.body.weight(.medium))
                .foregroundStyle(title.isEmpty ? .secondary : .primary)
                .lineLimit(2)
            HStack(spacing: 4) {
                if !subtitle.isEmpty {
                    Text(subtitle).lineLimit(1)
                }
                if !subtitle.isEmpty, date != nil {
                    Text(verbatim: "·")
                }
                if let date {
                    Text(date.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
