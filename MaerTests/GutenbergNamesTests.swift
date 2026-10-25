// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A Gutenberg title names its author and genres as a person reads them,
/// not in the record's catalogue form, at every way in.
struct GutenbergNamesTests {
    @Test("der Autor steht als Vorname Nachname, ohne Lebensdaten")
    func theAuthorReadsAsAName() {
        #expect(FreeCatalog.gutenbergAuthor("Swift, Jonathan, 1667-1745") == "Jonathan Swift")
        #expect(FreeCatalog.gutenbergAuthor("Swift, Jonathan") == "Jonathan Swift")
        #expect(FreeCatalog.gutenbergAuthor("Doyle, Arthur Conan, 1859-1930") == "Arthur Conan Doyle")
        #expect(FreeCatalog.gutenbergAuthor("Wells, H. G. (Herbert George), 1866-1946") == "H. G. Wells")
        #expect(FreeCatalog.gutenbergAuthor("Scott, Walter, Sir, 1771-1832") == "Sir Walter Scott")
        #expect(FreeCatalog.gutenbergAuthor("Homer, active 8th century B.C.") == "Homer")
        #expect(FreeCatalog.gutenbergAuthor("Anonymous") == "Anonymous")
        #expect(FreeCatalog.gutenbergAuthor(nil) == nil)
        #expect(FreeCatalog.gutenbergAuthor("") == nil)
    }

    @Test("ein Genre ist die Hauptueberschrift der Schlagwortkette, jede einmal")
    func aGenreIsTheChainsMainHeading() {
        #expect(FreeCatalog.gutenbergGenres(["Voyages, Imaginary -- Fiction", "Satire", "Voyages, Imaginary -- Juvenile fiction"])
                == ["Voyages, Imaginary", "Satire"])
        #expect(FreeCatalog.gutenbergGenres([]) == nil)
        #expect(FreeCatalog.gutenbergGenres(nil) == nil)
    }

    /// The subjects of Gulliver's Travels as the kept Gutenberg stock carries
    /// them (`gut:9272`).
    @Test("die echte Gulliver-Kette ergibt hoechstens drei Genres, die Figur faellt")
    func theGulliverChainGivesThreeGenresWithoutTheCharacter() {
        let gulliver = ["Fantasy fiction", "Satire", "Travelers -- Fiction",
                        "Gulliver, Lemuel (Fictitious character) -- Fiction",
                        "Voyages, Imaginary -- Early works to 1800"]
        #expect(FreeCatalog.gutenbergGenres(gulliver) == ["Fantasy fiction", "Satire", "Travelers"])
        // The character drops even where it would stand within the limit.
        #expect(FreeCatalog.gutenbergGenres(["Gulliver, Lemuel (Fictitious character) -- Fiction", "Satire"]) == ["Satire"])
        #expect(FreeCatalog.gutenbergGenreLimit == 3)
    }

    @Test("jeder Weg eines Gutenberg-Titels nimmt die beiden Regeln", .needsTheSources)
    func everyWayInTakesTheRules() throws {
        let provider = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/FreeCatalogProvider.swift"),
                       encoding: .utf8))
        #expect(provider.components(separatedBy: "FreeCatalog.gutenbergAuthor(").count - 1 == 3)
        #expect(provider.components(separatedBy: "FreeCatalog.gutenbergGenres(").count - 1 == 2)
    }
}
#endif
