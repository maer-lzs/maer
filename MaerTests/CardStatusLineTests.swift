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
    @Test("one line up to the usual size, two above it, up to the limit of the cards")
    func linesFollowTheTypeSize() {
        #expect(CardStatusLine.lines(for: .xSmall) == 1)
        #expect(CardStatusLine.lines(for: .large) == 1)
        #expect(CardStatusLine.lines(for: .xLarge) == 2)
        #expect(CardStatusLine.lines(for: .xxxLarge) == 2)
        #expect(CardStatusLine.lines(for: .accessibility1) == 2)
    }

    @Test("the line breaks only after the separator, never in the middle of an entry such as „vor 1 Stunde“")
    func theLineBreaksOnlyAfterTheSeparator() {
        let line = CardStatusLine.joined(["noch 24 Min.", "vor 1 Stunde"])
        #expect(line == "noch\u{00A0}24\u{00A0}Min.\u{00A0}· vor\u{00A0}1\u{00A0}Stunde", "\(line.unicodeScalars.map { String($0.value, radix: 16) })")
        // Exactly one place where a line may break: the space after the separator.
        #expect(line.filter { $0 == " " }.count == 1)
        #expect(CardStatusLine.joined(["Gehoert"]) == "Gehoert")
    }

    @Test("book line and episode line put their parts together through joined", .needsTheSources)
    func bothTextsJoinThroughTheRule() throws {
        let text = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CardStatusLine.swift"), encoding: .utf8))
        #expect(text.components(separatedBy: "return joined(").count - 1 == 2, "a text joins its parts by hand")
        #expect(!text.contains(".joined(separator: \" · \")"), "a plain separator lets a part break inside")
    }

    @Test("cards and Continue Listening pages say the same words: status line through CardStatusLine, text from one place", .needsTheSources)
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

    @Test("the book page says last listened with the words of the card", .needsTheSources)
    @MainActor
    func theBookPageSaysWhatTheCardSays() throws {
        // A server stand in seconds, as an old server or the seed once gave:
        // the card's words name the same moment as in milliseconds.
        let id = "card-equals-page-\(UUID().uuidString)"
        let ms = Date().timeIntervalSince1970 * 1000 - 26 * 3600 * 1000
        let heard = CardStatusLine.lastHeard(itemId: id, server: ms)
        #expect(heard != nil)
        #expect(CardStatusLine.lastHeard(itemId: id, server: ms / 1000) == heard)
        let page = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(page.contains("CardStatusLine.lastHeard(itemId: entry.id,"), "the book page names the moment by itself")
        #expect(!page.contains("lastUpdate / 1000"), "the book page reads the server stand raw")
    }
}
#endif
