// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The classical page holds more than the shellac shelf it is reached by:
/// it is called Classical and has two sections under their headings,
/// Musopen first, then Shellac. Every other shelf page keeps its title.
struct ClassicalPageTests {
    @Test("the classical page is called Classical, every other shelf keeps its title")
    func pageTitle() {
        #expect(ArchiveMusicCatalog.classical.isClassicalPage)
        #expect(ArchiveMusicCatalog.classical.pageTitle == String(localized: "Classical"))
        for shelf in ArchiveMusicCatalog.shellacShelves where shelf.key != ArchiveMusicCatalog.classical.key {
            #expect(!shelf.isClassicalPage && shelf.pageTitle == shelf.title, "\(shelf.key)")
        }
    }

    @Test("the page names itself by the rule and shows Musopen, the Gutenberg music, then the Shellac heading", .needsTheSources)
    func twoSections() throws {
        let page = SyncContractFenceTests.stripped(try SourceTree.text(
            SourceTree.root.appendingPathComponent("Sources/Views/Music/ArchiveMusicPages.swift")))
        #expect(page.contains(".navigationTitle(Text(verbatim: area.pageTitle))"))
        #expect(page.contains("""
                        if area.isClassicalPage {
                            MusopenRow(playerCoordinator: playerCoordinator, showsRights: true)
                                .padding(.bottom, 12)
                            GutenbergMusicRow(playerCoordinator: playerCoordinator, stockService: stockService)
                                .padding(.bottom, 12)
                            RowHeading.plain("Shellac")
"""), "the classical page has no Musopen section, then the Gutenberg music, then the Shellac heading")
        let catalog = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        #expect(catalog.contains("\"Shellac\" : {"), "the heading is not in the catalog")
    }
}
#endif
