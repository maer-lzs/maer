// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import SwiftUI
@testable import Maer

/// The status line of the featured cards wraps at large type instead of
/// being cut, and both cards draw it through the one building block.
struct CardStatusLineTests {
    @Test("eine Zeile bis zur ueblichen Groesse, darueber zwei, bis zur Grenze der Karten")
    func linesFollowTheTypeSize() {
        #expect(CardStatusLine.lines(for: .xSmall) == 1)
        #expect(CardStatusLine.lines(for: .large) == 1)
        #expect(CardStatusLine.lines(for: .xLarge) == 2)
        #expect(CardStatusLine.lines(for: .xxxLarge) == 2)
        #expect(CardStatusLine.lines(for: .accessibility1) == 2)
    }

    @Test("Karten und Weiterhoeren-Seiten sagen dieselben Worte: Statuszeile ueber CardStatusLine, Text aus einer Stelle", .needsTheSources)
    func cardsAndPagesUseTheOneLine() throws {
        let uses: [(file: String, needles: [String])] = [
            ("Sources/Views/BookFeaturedCard.swift", ["CardStatusLine(text:", "CardStatusLine.bookText(entry)"]),
            ("Sources/Views/Podcasts/PodcastComponents.swift", ["CardStatusLine(text: CardStatusLine.episodeText(item)"]),
            ("Sources/Views/MixedMediaPage.swift", ["meta: CardStatusLine.bookText(entry)", "meta: CardStatusLine.episodeText(item)"]),
            ("Sources/Views/PodcastsView.swift", ["meta: CardStatusLine.episodeText(item)"]),
        ]
        for use in uses {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent(use.file), encoding: .utf8)
            for needle in use.needles {
                #expect(text.contains(needle), "\(use.file) does not say \(needle)")
            }
            // The card's own forms of the words are gone.
            #expect(!text.contains("private var lastPlayedText"), "\(use.file) keeps its own last-heard words")
        }
    }
}
#endif
