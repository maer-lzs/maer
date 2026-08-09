// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// R1/R2 (09.08.): the shelves ask the server, and one page shows a title once.
struct CatalogShelfQueryTests {
    @Test("a shelf resolves to the LibriVox genres that fold onto it")
    func librivoxGenresPerShelf() {
        let scifi = CatalogGenreAxis.librivoxGenres(forShelf: "scifi")
        #expect(scifi.contains("science fiction"))
        #expect(!scifi.isEmpty)
        // A shelf key that does not exist yields nothing (no accidental
        // "everything" query).
        #expect(CatalogGenreAxis.librivoxGenres(forShelf: "does-not-exist").isEmpty)
    }

    @Test("a shelf resolves to subject terms for the subject-based catalogs")
    func subjectsPerShelf() {
        #expect(!CatalogGenreAxis.subjects(forShelf: "poetry").isEmpty)
        #expect(CatalogGenreAxis.subjects(forShelf: "does-not-exist").isEmpty)
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
