// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Outside the views, a place that reads a fact of the catalogue's register
/// takes the question as a parameter with the live register as default. A
/// witness hands in its own answer and sees it decide.
@MainActor
struct CatalogFactsParameterTests {
    static let item = LibraryItem(id: "lv:witness-reading", media: nil, addedAt: nil)

    @Test("die Suche nennt die Lesung, die ihr gereicht wird, und keine, wenn keine gereicht wird")
    func searchNamesTheReadingItIsHanded() {
        let second = GlobalSearchModel.bookResult(Self.item, source: "LibriVox", readingVersion: { _ in 2 })
        #expect(second.subtitle?.contains("2") == true, "die gereichte Lesung steht in der Zeile")
        let none = GlobalSearchModel.bookResult(Self.item, source: "LibriVox", readingVersion: { _ in nil })
        #expect(none.subtitle == Self.item.author, "ohne Lesung bleibt die Zeile beim Autor")
    }

    /// A work stays one entry, whatever the service would say: the form that
    /// is handed in decides, and a work is decided before any detail is asked.
    @Test("die Playlist-Erweiterung folgt der gereichten Form")
    func playlistExpansionFollowsTheFormItIsHanded() async {
        let id = FreeCatalog.archivePrefix + "witness-form"
        let expanded = await PlaylistPresenter.expandedCatalogRelease(id, archiveForm: { _ in .work })
        #expect(expanded.ids == [id] && expanded.titles.isEmpty, "ein Werk wird nicht in Titel zerlegt")
    }
}
#endif
