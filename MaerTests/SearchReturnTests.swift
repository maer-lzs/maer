// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Back from an author, a series or a group of the books tab, opened from
/// the search, leads into the search with its query and results; any other
/// push from the search closes it.
struct SearchReturnTests {
    @Test("ein anderer Weg aus der Suche schliesst sie")
    func anyOtherPushCloses() {
        var search = SearchReturn()
        #expect(search.pathChanged(from: 0, to: 1, showing: true) == .close)
        #expect(search.pathChanged(from: 1, to: 0, showing: false) == .none, "a closed search came back")
    }

    @Test("eine Seite der Hoerbuecher setzt die Suche beiseite; ein Buch von dort und zurueck fuehrt erst auf die Seite, dann in die Suche")
    func aBooksPageStepsAsideAndComesBack() {
        var search = SearchReturn()
        search.opensPage()
        #expect(search.pathChanged(from: 0, to: 1, showing: true) == .stepAside)
        #expect(search.pathChanged(from: 1, to: 2, showing: false) == .none, "the book from the page")
        #expect(search.pathChanged(from: 2, to: 1, showing: false) == .none, "back from the book is the page, not the search")
        #expect(search.pathChanged(from: 1, to: 0, showing: false) == .comeBack)
        // The opening was taken by its push: the next push closes again.
        #expect(search.pathChanged(from: 0, to: 1, showing: true) == .close)
    }

    @Test("nach einem Vergessen kommt die Suche nicht zurueck")
    func forgottenComesNotBack() {
        var search = SearchReturn()
        search.opensPage()
        #expect(search.pathChanged(from: 0, to: 1, showing: true) == .stepAside)
        search.forget()
        #expect(search.pathChanged(from: 1, to: 0, showing: false) == .none)
    }

    @Test("die Seite oeffnet von dem Stand, auf dem die Suche stand, und kommt dorthin zurueck")
    func comesBackAtItsOwnDepth() {
        var search = SearchReturn()
        search.opensPage()
        #expect(search.pathChanged(from: 2, to: 3, showing: true) == .stepAside)
        #expect(search.pathChanged(from: 3, to: 2, showing: false) == .comeBack)
    }
}
#endif
