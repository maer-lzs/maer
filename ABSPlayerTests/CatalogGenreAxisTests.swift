// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// R1/R2 (09.08.): the shelves ask the server, and one page shows a title once.
struct CatalogShelfQueryTests {
    @Test("a shelf resolves to subject terms for the subject-based catalogs")
    func subjectsPerShelf() {
        #expect(!CatalogGenreAxis.subjects(forShelf: "poetry").isEmpty)
        #expect(CatalogGenreAxis.subjects(forShelf: "does-not-exist").isEmpty)
    }

    /// BEFUND f220ecd (der Zaun dazu): jede Fläche derselben Quelle muss auf
    /// DERSELBEN Basis stehen. Der Regal-Pfad hatte die Basis nachgebaut und
    /// dabei drei beschlossene Punkte verloren — Entdopplung, Lizenzklausel
    /// und (über `isCuratedArchiveDoc`) die Sperrliste.
    @Test("every archive shelf stands on the source's ONE base query")
    func shelvesReuseTheBaseQuery() throws {
        let books = try #require(ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks))
        #expect(books.contains("NOT collection:librivoxaudio"),
                "without it a shelf shows the LibriVox duplicates again (measured: 1.098 of 1.602)")
        // R47 (the owner's ENTSCHEID): der Lizenzfilter ist vom ANZEIGE-Weg
        // GEFALLEN — „auch die Sachen ohne Lizenzangabe mit reinnehmen, sie
        // sind auf archive.org". Die Grenze sitzt jetzt am Kopieren
        // (`mayDownload`), nicht am Zeigen; die fehlende Angabe ist an der
        // Kachel SICHTBAR statt den Eintrag zu verschweigen.
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

        // Feed-based sources have no archive base — they must not silently
        // fall back to some other collection.
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .oerr) == nil)
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .independents) == nil)
    }

    @Test("the denylist is one truth — it filters wherever we assemble the offer")
    func denylistCoversEveryArchiveSurface() {
        // 893a7ea: same gate for row, trove, shelf and search. The pure
        // predicate is the single place; this pins that a known excluded id
        // is recognised, so a surface that forgets to call it stands out in
        // review rather than in a device session.
        let excluded = ArchivePopularDoc(
            identifier: "BearislandAM", title: ArchiveStringList(["Bear Island"]),
            creator: ArchiveStringList(["Alistair MacLean"]), downloads: 1,
            runtime: nil, licenseurl: nil, year: nil, subject: nil)
        #expect(!FreeCatalog.isCuratedArchiveDoc(excluded))
    }

    @Test("R2: a title belongs to its FIRST shelf in browse order")
    func primaryShelfIsFirstInBrowseOrder() {
        let order = CatalogGenreAxis.librivoxShelves.map(\.key)
        let philosophyFirst = order.firstIndex(of: "philosophy") ?? Int.max
        let religionFirst = order.firstIndex(of: "religion") ?? Int.max
        let expected = philosophyFirst < religionFirst ? "philosophy" : "religion"
        // Order of the ARGUMENT must not matter — browse order decides.
        #expect(CatalogGenreAxis.primaryShelf(among: ["religion", "philosophy"]) == expected)
        #expect(CatalogGenreAxis.primaryShelf(among: ["philosophy", "religion"]) == expected)
        #expect(CatalogGenreAxis.primaryShelf(among: []) == nil)
    }
}
#endif
