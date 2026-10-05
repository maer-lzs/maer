// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Start's Browse row and its page: three shares mixed rank by rank, one
/// entry with three switches on the rows page, and a page holding every
/// foreign source but the radio catalog.
struct BrowseTests {
    @Test("Rang um Rang, leere Anteile fallen weg, die Grenze haelt")
    func rankByRank() {
        #expect(BrowseMix.interleave([["r1", "r2", "r3"], ["m1"], ["b1", "b2"]], limit: 10)
                == ["r1", "m1", "b1", "r2", "b2", "r3"])
        #expect(BrowseMix.interleave([[], ["m1", "m2"], []], limit: 10) == ["m1", "m2"])
        #expect(BrowseMix.interleave([["r1", "r2"], ["m1", "m2"]], limit: 3) == ["r1", "m1", "r2"])
        #expect(BrowseMix.interleave([[String]](), limit: 5).isEmpty)
        #expect(BrowseMix.columns(["a", "b", "c"]) == [["a", "b"], ["c"]])
    }

    @Test("ein eingeschalteter, leerer Anteil nennt seinen Grund, ein ausgeschalteter nicht")
    func aDroppedShareSaysWhy() {
        #expect(BrowseMix.dropReason(.music, enabled: true, isEmpty: true, failure: "Jamendo: 429") == "music: Jamendo: 429")
        #expect(BrowseMix.dropReason(.books, enabled: true, isEmpty: true, failure: nil) == "books: no tiles")
        #expect(BrowseMix.dropReason(.music, enabled: false, isEmpty: true, failure: "x") == nil)
        #expect(BrowseMix.dropReason(.recommended, enabled: true, isEmpty: false, failure: nil) == nil)
    }

    @Test("die Seite haelt jede Quelle ausser dem Radio-Katalog")
    func thePageHoldsEverySourceButRadio() {
        let keys = Set(BrowseSection.allCases.flatMap(\.sourceKeys))
        for key in keys { #expect(ExternalSources.source(key: key) != nil, "\(key) is no source") }
        #expect(!keys.contains("radioBrowser"), "the radio catalog belongs to its tab")
        let browsed = ExternalSources.all.filter { $0.group == .catalogs }.map(\.key)
            + ["appleCatalog", "podcastIndex"]
        for key in browsed { #expect(keys.contains(key), "\(key) has no section") }
        // Every source off: the curated feeds still stand, nothing else.
        #expect(BrowseSection.shown(isAllowed: { _ in false }) == [.publicFeeds, .independentFeeds])
        #expect(BrowseSection.shown(isAllowed: { $0 == "jamendo" }).contains(.jamendo))
    }

    @Test("auf der Seite Reihen ist Stoebern eine Zeile mit drei Unter-Schaltern, die ihre Schluessel behalten")
    func browseIsOneEntryWithThreeSwitches() throws {
        let shares = AppRows.all.filter { $0.group == "home.browse" }
        #expect(shares.map(\.key) == ["home.recommendations", "home.discoverMusic", "home.discoverBooks"])
        #expect(shares.map(\.storageKey) == [AppStorageKeys.homeRecommendations,
                                             AppStorageKeys.rowHomeDiscoverMusicVisible,
                                             AppStorageKeys.rowHomeDiscoverBooksVisible],
                "a share lost its stored choice")
        #expect(AppRows.groupTitle("home.browse") != nil)
        #expect(AppRows.all.filter { $0.group != nil }.allSatisfy { AppRows.groupTitle($0.group!) != nil })
    }

    @Test("der Start zeichnet Stoebern aus den drei Anteilen und sagt, warum einer fehlt", .needsTheSources)
    func startDrawsBrowse() throws {
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("if browseVisible { browseSection }"))
        #expect(home.contains("BrowseMix.interleave(browseShares, limit: RowPreview.limit * 2)"))
        #expect(home.contains("BROWSE share dropped"), "a share that falls away says nothing")
        #expect(!home.contains("{ discoverSection }") && !home.contains("discoverAudiobooksSection")
                && !home.contains("FreeCatalogRows("),
                "a single row stands beside Browse")
        let rows = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/RowsSettingsView.swift"), encoding: .utf8))
        #expect(rows.contains("AppRows.groupTitle(group)"), "the rows page draws the shares without their title")
    }
}
#endif
