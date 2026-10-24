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
    @Test("the book page asks the rule and embeds the chapters in the wide form")
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
        #expect(page.components(separatedBy: "DetailCoverSide.side(").count - 1 == 2)
        // Three forms and the definition.
        #expect(page.components(separatedBy: "buttonRow(width:").count - 1 == 4)
        #expect(!page.contains("HStack(spacing: 12) {\n                                downloadSection"))
    }
}
#endif
