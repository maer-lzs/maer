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

    @Test("Buch- und Folgenkarte zeichnen ihre Statuszeile ueber CardStatusLine", .needsTheSources)
    func bothCardsUseTheOneLine() throws {
        for file in ["Sources/Views/BookFeaturedCard.swift", "Sources/Views/Podcasts/PodcastComponents.swift"] {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("CardStatusLine(text:"), "\(file) draws its status line by hand")
            #expect(!text.contains("[remainingText, lastPlayedText].compactMap { $0 }.joined(separator: \" · \")).font"),
                    "\(file) keeps a second form of the line")
        }
    }
}
#endif
