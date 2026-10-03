// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The shelves ask the server, and one page shows a title once.
struct CatalogShelfQueryTests {
    @Test("a shelf resolves to subject terms for the subject-based catalogs")
    func subjectsPerShelf() {
        #expect(!CatalogGenreAxis.subjects(forShelf: "poetry").isEmpty)
        #expect(CatalogGenreAxis.subjects(forShelf: "does-not-exist").isEmpty)
    }

    /// Jede Fläche derselben Quelle muss auf
    /// DERSELBEN Basis stehen. Der Regal-Pfad hatte die Basis nachgebaut und
    /// dabei drei beschlossene Punkte verloren. Entdopplung, Lizenzklausel
    /// und (über `isCuratedArchiveDoc`) die Sperrliste.
    @Test("every archive shelf stands on the source's ONE base query")
    func shelvesReuseTheBaseQuery() throws {
        let books = try #require(ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks))
        #expect(books.contains("NOT collection:librivoxaudio"),
                "without it a shelf shows the LibriVox duplicates again (measured: 1.098 of 1.602)")
        // Der Lizenzfilter ist vom ANZEIGE-Weg gefallen: die Grenze sitzt am
        // Kopieren (`mayDownload`), nicht am Zeigen, und die fehlende Angabe
        // ist an der Kachel SICHTBAR statt den Eintrag zu verschweigen.
        #expect(!books.contains("licenseurl"),
                "die Anzeige filtert wieder nach Lizenz")
        #expect(books.contains("mediatype:(audio)"),
                "without it the collection also returns TEXT items")

        let otr = try #require(ArchiveOrgClient.archiveBaseQuery(for: .oldTimeRadio))
        #expect(!otr.contains("licenseurl"), "die OTR-Anzeige filtert wieder nach Lizenz")
        #expect(otr.contains("mediatype:(audio)"))
        // Die andere Haelfte des Entscheids muss dabei greifen.
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
        #expect(FreeCatalog.mayDownload(licenceURL: "https://creativecommons.org/licenses/by/4.0/"))

        // Feed-based sources have no archive base. They must not silently
        // fall back to some other collection.
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .oerr) == nil)
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .independents) == nil)
    }

    @Test("the denylist is one truth — it filters wherever we assemble the offer")
    func denylistCoversEveryArchiveSurface() {
        // Same gate for row, trove, shelf and search. The pure
        // predicate is the single place; this pins that a known excluded id
        // is recognised, so a surface that forgets to call it stands out in
        // review rather than in a device session.
        let excluded = ArchivePopularDoc(
            identifier: "BearislandAM", title: ArchiveStringList(["Bear Island"]),
            creator: ArchiveStringList(["Alistair MacLean"]), downloads: 1,
            runtime: nil, licenseurl: nil, year: nil, subject: nil)
        #expect(!FreeCatalog.isCuratedArchiveDoc(excluded))
    }
}

/// Die Kopf-Regel der gefilterten Flaechen: eine gefilterte Flaeche darf
/// nie aussehen wie der volle Bestand; der Titel nennt den Filter, und
/// ohne Filter aendert sich nichts.
struct FilteredHeadTests {
    @Test("der Titel nennt den aktiven Filter und sonst nichts")
    func headNamesTheFilter() {
        #expect(FilteredHead.title("All Books", filterLabel: "Unfinished")
                == "All Books · Unfinished")
        #expect(FilteredHead.title("All Books", filterLabel: nil) == "All Books")
        #expect(FilteredHead.title("All Books", filterLabel: "") == "All Books")
        #expect(SortIndicator.part("Unfinished", ifNot: false) == "Unfinished")
        #expect(SortIndicator.part("All", ifNot: true) == nil)
    }
}
#endif
