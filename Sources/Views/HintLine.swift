// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE orange hint line of a section: a sentence that says why something
/// does not work as one would expect, with its symbol; the sentence in the
/// footnote size, sentence and symbol in orange. It stood by hand in ten
/// places, and the copies drifted in size (footnote, caption, body) and in
/// colour (the whole line, or the symbol alone).
///
/// A status inside a row stays with its row's siblings and is another form:
/// the import result in the catalog, the guard note in the sync history,
/// the notes of the row settings (text without a symbol), the banner of a
/// refused show (a title with a symbol). The fence counts the orange sites
/// of the views per file with their reason.
struct HintLine<Content: View>: View {
    let systemImage: String
    let content: Content

    init(systemImage: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        Label {
            content.font(.footnote)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.orange)
    }
}
