// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An author hit in search opens the books of that author. The field it
/// has to match carries two shapes: the same person written the other way
/// round, and several people in one field.
struct AuthorMatchTests {
    @Test("Derselbe Mensch, andersherum geschrieben: Nachname, Vorname trifft Vorname Nachname")
    func swappedNameIsTheSamePerson() {
        #expect(AuthorMatch.field("Tolkien, J. R. R.", names: "J. R. R. Tolkien"))
        #expect(AuthorMatch.field("J. R. R. Tolkien", names: "Tolkien, J. R. R."))
        #expect(AuthorMatch.field("Döblin, Alfred", names: "Alfred Doblin"), "folded diacritics")
        #expect(!AuthorMatch.field("Tolkien, Christopher", names: "J. R. R. Tolkien"))
    }

    @Test("Mehrere Menschen in einem Feld: ein sicherer Trenner teilt, ein Komma nie")
    func severalPeopleInOneField() {
        #expect(AuthorMatch.field("Neil Gaiman & Terry Pratchett", names: "Terry Pratchett"))
        #expect(AuthorMatch.field("Neil Gaiman; Terry Pratchett", names: "Neil Gaiman"))
        #expect(AuthorMatch.field("Grimm und Grimm", names: "Grimm"))
        // The comma stays undivided: "Tolkien, J. R. R." would fall apart
        // into two people, and which of the two shapes a comma means is
        // not decidable without measured data. Named limit.
        #expect(AuthorMatch.people(in: "Tolkien, J. R. R.") == ["Tolkien, J. R. R."])
        #expect(AuthorMatch.people(in: "A & B").count == 2)
    }

    @Test("Die Form: gefaltet, ohne Zeichensetzung, ohne doppelte Leerzeichen; Leeres trifft nichts")
    func normalisationAndEmptiness() {
        #expect(AuthorMatch.normalized("  J.  R. R.  Tolkien ") == "j r r tolkien")
        #expect(AuthorMatch.forms(of: "Tolkien, J. R. R.").contains("j r r tolkien"))
        #expect(!AuthorMatch.field(nil, names: "Tolkien"))
        #expect(!AuthorMatch.field("", names: "Tolkien"))
        #expect(!AuthorMatch.field("Tolkien", names: ""))
        #expect(!AuthorMatch.field("Tolkien", names: "."), "punctuation alone names nobody")
    }

    @Test("Der Autor-Treffer traegt die Route der Bibliothek, keinen eigenen Weg der Suche", .needsTheSources)
    func searchPushesTheLibraryRoute() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/SearchScreen.swift"), encoding: .utf8)
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The library's route, opened so the search comes back (`SearchReturn`).
        #expect(code.contains("onOpenLibraryPage(.author("))
        #expect(code.contains("onOpenLibraryPage(.series("))
        #expect(!code.contains("pushEntries("), "the search's own drill for a hit is gone")
    }
}
#endif
