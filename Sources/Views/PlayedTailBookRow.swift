// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A book's own "counts as played" choice, on its page. The same values and
/// labels as the show field (`PodcastGeneralField.playedTail`); the first
/// choice follows the general value.
struct PlayedTailBookRow: View {
    let itemId: String
    @State private var own: String?

    private let field = PodcastGeneralField.playedTail

    var body: some View {
        Picker(field.name, selection: Binding(
            get: { own },
            set: { raw in
                PlayedTail.set(raw.flatMap(Double.init), ownerId: itemId)
                own = PlayedTail.stored(itemId).map { String(Int($0)) }
            })) {
            Text("As for all (\(field.label(field.general)))").tag(String?.none)
            ForEach(field.choices, id: \.self) { raw in
                Text(field.label(raw)).tag(String?.some(raw))
            }
        }
        .choicesAsRowsWhenLarge()
        .accessibilityIdentifier("book-played-tail")
        .onAppear { own = PlayedTail.stored(itemId).map { String(Int($0)) } }
    }
}
