// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Details" on a catalogue tile opens the title's page, the one the full
/// player's source tap opens; no surface presents a floating details sheet.
struct CatalogDetailsPageTests {
    @Test("Details picks the page like the player: song to the release, album to the album page, reading to the book page")
    func detailsPicksThePlayersPage() {
        // A release not started yet on a music surface: its album page.
        guard case .catalogAlbum(let album) = CatalogDetailsPage.target(
            itemId: "lva:MIXG032", startedForm: nil, unstartedForm: .album) else {
            Issue.record("an unstarted release on a music surface leads to a book page"); return
        }
        #expect(album == "lva:MIXG032")
        // Started as a work, the started form wins over the surface.
        guard case .catalogBook(let work) = CatalogDetailsPage.target(
            itemId: "lva:otr_x", startedForm: .work, unstartedForm: .album) else {
            Issue.record("a work started as one leads to the album page"); return
        }
        #expect(work == "lva:otr_x")
        // A song opens its release.
        let song = CatalogSongID.make(album: "lva:MIXG032", index: 3)
        guard case .catalogAlbum(let release) = CatalogDetailsPage.target(
            itemId: song, startedForm: nil, unstartedForm: .album) else {
            Issue.record("a song does not lead to its release"); return
        }
        #expect(release == "lva:MIXG032")
        // A reading is a book whatever the surface names.
        guard case .catalogBook = CatalogDetailsPage.target(
            itemId: "lv:59", startedForm: nil, unstartedForm: .album) else {
            Issue.record("a LibriVox reading leads to the album page"); return
        }
        guard case .catalogAlbum = CatalogDetailsPage.target(
            itemId: "jam:991", startedForm: nil, unstartedForm: nil) else {
            Issue.record("a Jamendo title leads to a book page"); return
        }
    }

    @Test("no floating detail sheet anymore; every Details of a catalog tile is the one button", .needsTheSources)
    func noSurfacePresentsTheDetailsSheet() throws {
        let sources = ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"])
        try #require(sources.count > 100, "the fence did not read the views")
        var buttons = 0
        for (name, raw) in sources {
            let text = SyncContractFenceTests.stripped(raw)
            #expect(!text.contains("FreeCatalogDetailSheet"), "\(name) presents the details sheet")
            #expect(!text.contains("$detailItem") && !text.contains("$freeDetailItem"),
                    "\(name) keeps a sheet item for catalogue details")
            buttons += text.components(separatedBy: "CatalogDetailsButton(itemId:").count - 1
        }
        // The album and playlist menu (`CollectionMenuItems`, for the music
        // tiles of BrowseRow and the music tab), the area, popular row, genre rows and shelf of an archive
        // music area, the shellac rows, the Jamendo page and shelf.
        #expect(buttons == 8)
        let row = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BrowseRow.swift"), encoding: .utf8))
        #expect(row.contains("CatalogDetailsPage.open(itemId: item.id, unstartedForm: .album,"))
    }

    @Test("the page of a Jamendo title names the provider and leads to the source", .needsTheSources)
    func aJamendoPageNamesItsProvider() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        #expect(page.contains("Label(\"Creative Commons, via Jamendo\", systemImage: \"checkmark.seal\")"))
        #expect(page.contains("if let source = catalogFacts.sourceURL(itemId) {"))
        #expect(page.contains("sourceLines\n        } actions: {"))
    }
}
#endif
