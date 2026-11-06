// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The book page's form by its window: two columns only where it is wide
/// and not a phone on its side; folded and on the iPhone it stays as it was.
struct BookDetailLayoutTests {
    @Test("the open Duo on its side and an iPad in landscape get two columns")
    func wideWindowsGetTwoColumns() {
        #expect(BookDetailLayout.of(width: 951, height: 678, compactHeight: false) == .twoColumns)
        #expect(BookDetailLayout.of(width: 1366, height: 1024, compactHeight: false) == .twoColumns)
    }

    @Test("a phone on its side, the folded Duo on its side and upright windows keep their form")
    func otherWindowsKeepTheirForm() {
        #expect(BookDetailLayout.of(width: 956, height: 440, compactHeight: true) == .sideBySide)
        #expect(BookDetailLayout.of(width: 678, height: 466, compactHeight: false) == .sideBySide)
        #expect(BookDetailLayout.of(width: 440, height: 956, compactHeight: false) == .hero)
        #expect(BookDetailLayout.of(width: 678, height: 951, compactHeight: false) == .hero)
        #expect(BookDetailLayout.of(width: 1024, height: 1366, compactHeight: false) == .hero)
        // The first layout pass can report no height: never the wide form then.
        #expect(BookDetailLayout.of(width: 951, height: 0, compactHeight: false) == .hero)
    }

    /// The fence: the page decides its form through the one rule, and the
    /// wide form shows the chapter list in place, not the link to it.
    @Test("the book page asks the rule and embeds the chapters in the wide form", .needsTheSources)
    func thePageUsesTheRule() throws {
        let page = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8)
        #expect(page.contains("BookDetailLayout.of(width: geo.size.width, height: geo.size.height"))
        #expect(page.contains("trailingSections(isHero: false, showsChapterLink: false)"))
        #expect(page.contains("embedded: true"))
        #expect(!page.contains("geo.size.width > geo.size.height"))
        // The wide form divides at the fold, the cover follows the height in
        // both forms, the two buttons stand whole.
        #expect(page.contains("FoldColumns { column in"))
        // The two-column cover takes the rule itself, the hero through the card.
        #expect(page.components(separatedBy: "DetailCoverSide.side(").count - 1 == 1)
        #expect(page.components(separatedBy: "DetailCoverCard.form(").count - 1 == 1)
        // Three forms and the definition.
        #expect(page.components(separatedBy: "buttonRow(width:").count - 1 == 4)
        #expect(!page.contains("HStack(spacing: 12) {\n                                downloadSection"))
    }
}

/// One plain text from the HTML of a description, for books, shows and
/// episodes: the same answer every time, `&amp;` decoded last.
struct HTMLPlainTextTests {
    @Test("eine Beschreibung wird jedes Mal gleich zu Text, ein maskiertes Zeichen bleibt maskiert")
    func theEntitiesDecodeInOneOrder() {
        #expect(htmlPlainText("&amp;lt;b&amp;gt;") == "&lt;b&gt;", "an escaped entity stays the text it names")
        #expect(htmlPlainText("<p>Kapitel&nbsp;1 &amp; 2</p><br/>&quot;Ja&quot;, sagt &apos;er&#39; &lt;leise&gt;")
                == "Kapitel 1 & 2\n\n\n\"Ja\", sagt 'er' <leise>")
        #expect(htmlEntities.last?.entity == "&amp;", "the ampersand goes last")
    }

    @Test("Buchseite und Podcastseiten nehmen eine Fassung der Ersetzung", .needsTheSources)
    func oneVersionOfTheCleanup() throws {
        var tables: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            // A table that decodes the entities, as pairs or as a dictionary.
            let code = SyncContractFenceTests.stripped(text)
            if code.contains(#""&lt;", "<""#) || code.contains(#""&lt;": "<""#) { tables.append(file) }
        }
        #expect(tables == ["PodcastHelpers.swift"], "the entities are decoded elsewhere too: \(tables)")
        let book = try FetchAnswerTests.squeezedSource("Sources/Views/BookDetailScreen.swift")
        #expect(book.contains("Text(htmlPlainText(description))"))
    }
}
#endif
