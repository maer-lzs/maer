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

    @Test("jeder Reiter hat seinen Bereich der Seite, Radio und Start keinen")
    func eachTabHasItsArea() {
        #expect(TabBrowse.area(for: .audiobooks) == .books)
        #expect(TabBrowse.area(for: .music) == .music)
        #expect(TabBrowse.area(for: .podcasts) == .podcasts)
        #expect(TabBrowse.area(for: .radio) == nil)
        #expect(TabBrowse.area(for: .home) == nil)
        let all: (String) -> Bool = { _ in true }
        #expect(BrowseSection.shown(in: .books, isAllowed: all) == [.librivox, .gutenberg, .archiveBooks, .oldTimeRadio])
        #expect(BrowseSection.shown(in: .music, isAllowed: all) == [.classical, .netlabels, .oldRecords, .jamendo])
        #expect(BrowseSection.shown(in: .podcasts, isAllowed: all)
                == [.recommendations, .charts, .publicFeeds, .independentFeeds],
                "the feeds of broadcasters and studios are shows to subscribe to")
        #expect(BrowseSection.shown(in: nil, isAllowed: all) == BrowseSection.allCases)
        #expect(BrowseSection.shown(in: .books, isAllowed: { _ in false }).isEmpty)
    }

    @Test("ohne Server die Abschnitte des Bereichs, mit Server die eine Reihe, je Reiter mit seinem Server")
    func sectionsWithoutServerRowWithServer() {
        #expect(TabBrowse.form(hasServer: false) == .sections)
        #expect(TabBrowse.form(hasServer: true) == .row)
        func form(_ tab: MediaType, abs: Bool = false, music: Bool = false, podcasts: Bool = false) -> TabBrowse.Form {
            TabBrowse.form(hasServer: TabBrowse.hasServer(for: tab, absSignedIn: abs, musicServer: music, absPodcasts: podcasts))
        }
        #expect(form(.audiobooks) == .sections)
        #expect(form(.audiobooks, abs: true) == .row)
        #expect(form(.audiobooks, music: true, podcasts: true) == .sections, "another area's server does not count")
        #expect(form(.music) == .sections)
        #expect(form(.music, music: true) == .row)
        #expect(form(.music, abs: true) == .sections)
        #expect(form(.podcasts) == .sections)
        #expect(form(.podcasts, abs: true) == .sections, "an Audiobookshelf without a podcast library")
        #expect(form(.podcasts, podcasts: true) == .sections, "a podcast library without a session")
        #expect(form(.podcasts, abs: true, podcasts: true) == .row)
    }

    @Test("jeder Reiter fragt die Regel und zieht seine Reihe aus den Abschnitten der Seite", .needsTheSources)
    func everyTabTakesTheRule() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let tabs = [("Sources/Views/LibraryView.swift", "books"),
                    ("Sources/Views/Music/MusicView.swift", "music"),
                    ("Sources/Views/PodcastsView.swift", "podcasts")]
        for (path, area) in tabs {
            let code = try flat(path)
            #expect(code.contains("switchTabBrowse.form(hasServer:"), "\(path) decides its form elsewhere")
            #expect(code.contains("BrowsePage.rowTiles(in:.\(area))"), "\(path) builds its row past the page's sections")
            #expect(code.contains("area:.\(area))"), "\(path) draws no Browse row of its area")
            #expect(code.contains("OpenCatalogsHeading()"), "\(path) shows its sections without the heading")
        }
        let library = try flat("Sources/Views/LibraryView.swift")
        #expect(library.contains("navigationDestination(for:BrowseRoute.self)"))
        #expect(library.contains("BrowsePage(freeCatalogStore:freeCatalogStore,area:route.area)"))
        let page = try flat("Sources/Views/BrowseRow.swift")
        #expect(page.contains("BrowseSection.shown(in:area,isAllowed:Self.isAllowed)"))
        #expect(page.contains("BrowseMix.interleave(BrowseSection.shown(in:area,isAllowed:isAllowed).map(lane)"))
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
