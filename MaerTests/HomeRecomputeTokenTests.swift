// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Home recomputes on a change of content, never of a count.
struct HomeRecomputeTokenTests {
    static func token(entries: [String] = ["a", "b"], added: [String] = ["a"], queue: [String] = ["q1", "q2"],
                      continuing: [(id: String, lastUpdate: Double)] = [("a", 1)]) -> String {
        HomeRecomputeToken.make(isActive: true, entryIds: entries, continueEntries: continuing,
                                recentlyAddedIds: added, queueIds: queue, recommendationsEnabled: true,
                                hiddenRevision: 0, showFeeds: [], revision: 0)
    }

    @Test("eine Liste, die sich bei gleicher Laenge aendert, aendert das Zeichen")
    func equalLengthOtherContentChangesTheToken() {
        let base = Self.token()
        #expect(Self.token(entries: ["a", "c"]) != base, "die Bibliothek")
        #expect(Self.token(added: ["b"]) != base, "zuletzt hinzugefuegt")
        #expect(Self.token(queue: ["q1", "q3"]) != base, "die Warteschlange")
        #expect(Self.token(continuing: [("a", 2)]) != base, "ein Weiterhoeren-Eintrag, der sich bewegt")
    }

    @Test("die Reihenfolge der Warteschlange zaehlt, die der Bibliothek nicht")
    func theQueueOrderCountsTheLibraryOrderDoesNot() {
        #expect(Self.token(queue: ["q2", "q1"]) != Self.token(), "Up Next zeigt die Reihenfolge")
        #expect(Self.token(entries: ["b", "a"]) == Self.token(), "die Bibliothek ist eine Menge")
        #expect(Self.token() == Self.token(), "gleicher Inhalt, gleiches Zeichen")
    }

    @Test("Homes Zeichen zaehlt keine Liste", .needsTheSources)
    func homeCountsNoList() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "private var recomputeToken: String {", in: text))
        #expect(!body.contains(".count"), "das Zeichen zaehlt wieder eine Anzahl")
        #expect(body.contains("HomeRecomputeToken.make("))
    }
}
#endif
