// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// In two columns an area's title stands once: an area that runs on into
/// the trailing column keeps its title's room there without the title.
struct BrowseColumnTitleTests {
    @Test("two columns: the title of an area that continues into the second column appears only on the left")
    func aContinuedAreaTitlesOnce() {
        let books: [BrowseSection] = [.librivox, .gutenberg, .archiveBooks, .oldTimeRadio, .publicFeeds, .independentFeeds]
        let halves = BrowseSection.columns(books)
        #expect(!halves.leading.isEmpty && !halves.trailing.isEmpty, "the precondition: the area spans both columns")
        #expect(BrowseSection.continuedGroups(leading: halves.leading, trailing: halves.trailing) == [.books])
        // Areas that end in the leading column title the trailing one themselves.
        let split = BrowseSection.continuedGroups(leading: [.recommendations, .charts], trailing: [.classical, .librivox])
        #expect(split.isEmpty)
    }

    @Test("the second column keeps the title of a continued area hidden", .needsTheSources)
    func theTrailingColumnHidesTheContinuedTitle() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BrowseRow.swift"), encoding: .utf8))
        #expect(page.contains("continued: BrowseSection.continuedGroups(leading: halves.leading, trailing: halves.trailing)"),
                "the trailing column titles every area again")
        #expect(page.contains(".opacity(continued.contains(group) ? 0 : 1)"))
        #expect(page.contains(".accessibilityHidden(continued.contains(group))"), "VoiceOver reads the title twice")
    }
}
#endif
