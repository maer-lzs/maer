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
    @Test("Rank by rank, empty shares drop out, the limit holds")
    func rankByRank() {
        #expect(BrowseMix.interleave([["r1", "r2", "r3"], ["m1"], ["b1", "b2"]], limit: 10)
                == ["r1", "m1", "b1", "r2", "b2", "r3"])
        #expect(BrowseMix.interleave([[], ["m1", "m2"], []], limit: 10) == ["m1", "m2"])
        #expect(BrowseMix.interleave([["r1", "r2"], ["m1", "m2"]], limit: 3) == ["r1", "m1", "r2"])
        #expect(BrowseMix.interleave([[String]](), limit: 5).isEmpty)
        #expect(BrowseMix.columns(["a", "b", "c"]) == [["a", "b"], ["c"]])
    }

    @Test("only a row with more than one kind draws the kind per tile")
    func onlyAMixedRowMarksKinds() {
        #expect(!BrowseMix.marksKinds([MediaType.music, .music, .music]), "a music row")
        #expect(!BrowseMix.marksKinds([MediaType.audiobooks, .audiobooks]), "a books row")
        #expect(!BrowseMix.marksKinds([MediaType.podcasts, nil, .podcasts]), "a tile of no known kind does not mix")
        #expect(!BrowseMix.marksKinds([MediaType?]()))
        #expect(BrowseMix.marksKinds([MediaType.podcasts, .music, .audiobooks]), "Start")
        #expect(BrowseMix.marksKinds([MediaType.music, .audiobooks]))
    }

    @Test("every tile of the row names its kind, the drawing of the row asks the rule", .needsTheSources)
    func theRowAsksTheRule() throws {
        #expect(BrowseTile.music(LibraryItem(id: "jam:7", media: nil, addedAt: nil)).kind == .music)
        #expect(BrowseTile.catalog(.item(LibraryItem(id: "lv:123", media: nil, addedAt: nil))).kind == .audiobooks)
        let row = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BrowseRow.swift"), encoding: .utf8))
        #expect(row.contains("BrowseMix.marksKinds(tiles.map(\\.kind))"))
        #expect(!row.contains(".stackedKind(.podcasts)") && !row.contains(".stackedKind(.music)")
                && !row.contains("marksKind: true"), "a pure row marks its tiles")
    }

    @Test("the page splits its sections at the fold: the first half before it, the rest after it, in sequence")
    func thePageSplitsAtTheFold() {
        let all: (String) -> Bool = { _ in true }
        let music = BrowseSection.columns(BrowseSection.shown(in: .music, isAllowed: all))
        #expect(music.leading == [.classical, .netlabels] && music.trailing == [.oldRecords, .jamendo])
        let three = BrowseSection.columns([.librivox, .gutenberg, .archiveBooks])
        #expect(three.leading == [.librivox, .gutenberg] && three.trailing == [.archiveBooks])
        let start = BrowseSection.columns(BrowseSection.allCases)
        #expect(start.leading + start.trailing == BrowseSection.allCases, "nothing lost, nothing twice")
        #expect(BrowseSection.columns([]).leading.isEmpty && BrowseSection.columns([]).trailing.isEmpty)
    }

    @Test("every section of the page is a row with tiles, two columns at the fold", .needsTheSources)
    func everySectionIsALane() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BrowseRow.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(page.contains("BrowseLane(tiles:tiles(section),problem:problem(section)"), "a section is a link again")
        #expect(page.contains("lethalves=BrowseSection.columns(sections)FoldColumns{"), "the page lies over the fold")
        #expect(page.contains("lanes(halves.leading).environment(\\.sideColumnReach,0)"),
                "the leading column's rows reach over the fold")
        #expect(page.contains("BrowseTileView(tile:tile,marksKinds:false"), "a lane of one kind marks its tiles")
        // Every section names its tiles: a new section without a lane does not compile
        // past `tiles(_:)`, and none answers with a fixed empty list.
        #expect(!page.contains("default:return[]"))
    }

    /// Records the order in which the steps finish.
    @MainActor private final class Finished {
        var names: [String] = []
    }

    @Test("the page loads its areas at the same time: the duration is that of the longest, each comes with its answer")
    @MainActor func theLoadsRunSideBySide() async {
        let finished = Finished()
        func step(_ name: String, _ ms: Int) -> BrowseLoad.Step {
            {
                try? await Task.sleep(for: .milliseconds(ms))
                finished.names.append(name)
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        await BrowseLoad.together([step("catalogs", 900), step("recommendations", 300), step("charts", 600)])
        let elapsed = clock.now - start
        // One after the other would take 1.8 s; side by side the slowest decides.
        #expect(elapsed < .milliseconds(1500), "\(elapsed)")
        #expect(finished.names == ["recommendations", "charts", "catalogs"], "a lane waited for another")
        await BrowseLoad.together([])
    }

    @Test("the Browse page hands every area to the simultaneous loading, none waits for another", .needsTheSources)
    func thePageLoadsItsSectionsTogether() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BrowseRow.swift"), encoding: .utf8))
        let load = try #require(page.components(separatedBy: "private func load() async {").last?
            .components(separatedBy: "private static func title(").first)
        #expect(load.contains("await BrowseLoad.together(steps)"))
        #expect(load.components(separatedBy: "steps.append {").count - 1 == 4, "a section left the side-by-side load")
        // Every await of a load stands inside its step.
        for line in load.components(separatedBy: "\n") where line.contains("await ") {
            #expect(line.contains("steps.append { await ") || line.hasPrefix(String(repeating: " ", count: 16))
                    || line.contains("await BrowseLoad.together(steps)"),
                    "a load runs before the others: \(line)")
        }
    }

    @Test("a switched-on, empty share names its reason, a switched-off one does not")
    func aDroppedShareSaysWhy() {
        #expect(BrowseMix.dropReason(.music, enabled: true, isEmpty: true, failure: "Jamendo: 429") == "music: Jamendo: 429")
        #expect(BrowseMix.dropReason(.books, enabled: true, isEmpty: true, failure: nil) == "books: no tiles")
        #expect(BrowseMix.dropReason(.music, enabled: false, isEmpty: true, failure: "x") == nil)
        #expect(BrowseMix.dropReason(.recommended, enabled: true, isEmpty: false, failure: nil) == nil)
    }

    @Test("the page holds every source except the radio catalog")
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

    @Test("on the Rows page Browse is one line with three sub-switches that keep their keys")
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

    @Test("every tab has its area of the page, Radio and Start have none")
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

    @Test("without a server the sections of the area, with a server the one row, per tab with its server")
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

    @Test("every tab asks the rule and draws its row from the sections of the page", .needsTheSources)
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
        #expect(library.contains("BrowsePage(freeCatalogStore:freeCatalogStore,playerCoordinator:playerCoordinator,area:route.area)"))
        let page = try flat("Sources/Views/BrowseRow.swift")
        #expect(page.contains("BrowseSection.shown(in:area,isAllowed:Self.isAllowed)"))
        #expect(page.contains("BrowseMix.interleave(BrowseSection.shown(in:area,isAllowed:isAllowed).map(lane)"))
    }

    @Test("Start draws Browse from the three shares and says why one is missing", .needsTheSources)
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

    /// The part of a section in one of the page's two switches.
    private func arm(_ section: BrowseSection, in text: String, from start: String, to end: String) throws -> String {
        let open = try #require(text.range(of: start), "the switch \(start) is gone")
        let close = try #require(text.range(of: end, range: open.upperBound..<text.endIndex), "\(end) is gone")
        let body = text[open.upperBound..<close.lowerBound]
        let arms = body.components(separatedBy: "case .").filter { $0.hasPrefix("\(section.rawValue):") }
        #expect(arms.count == 1, "\(section.rawValue): \(arms.count) arms in \(start)")
        return arms.first ?? ""
    }

    /// Every lane's heading leads to the surface its tiles come from: per
    /// section the heading's destination and the store its tiles read, and
    /// for the two archive lanes the area the loader fills them from. A new
    /// section has to name its pair here.
    @Test("every heading of a row on Browse leads to the surface its tiles come from", .needsTheSources)
    func everyHeadingLeadsWhereItsTilesComeFrom() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/BrowseRow.swift")
        let pairs: [BrowseSection: (heading: String, tiles: String)] = [
            .recommendations: ("destination: PodcastRoute.recommendations)", "excludingOwned(recommendations.results)"),
            .charts: ("destination: PodcastRoute.charts)", "return charts.map(BrowseTile.recommendation)"),
            .classical: ("destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.classical))", "freeCatalogStore.rows.classical"),
            .netlabels: ("destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))", "freeCatalogStore.rows.netlabels"),
            .oldRecords: ("destination: MusicRoute.shellacArea)", "oldRecords.map(BrowseTile.music)"),
            .jamendo: ("destination: MusicRoute.freeJamendo)", "freeCatalogStore.rows.freeMusic"),
            .librivox: ("destination: FreeAudiobooksRoute.source(.librivox))", "sourceRows.librivoxPopular"),
            .gutenberg: ("destination: FreeAudiobooksRoute.source(.gutenberg))", "sourceRows.gutenberg"),
            .archiveBooks: ("destination: FreeAudiobooksRoute.source(.archiveBooks))", "sourceRows.archiveBooks"),
            .oldTimeRadio: ("destination: FreeAudiobooksRoute.source(.oldTimeRadio))", "sourceRows.oldTimeRadio"),
            .publicFeeds: ("destination: FreeAudiobooksRoute.oerrCountries)", "OERRLiveStore.feeds(for: .oerr,"),
            .independentFeeds: ("destination: FreeAudiobooksRoute.source(.independents))", "OERRLiveStore.feeds(for: .independents,"),
        ]
        #expect(Set(pairs.keys) == Set(BrowseSection.allCases),
                "a lane without its pair: \(Set(BrowseSection.allCases).subtracting(pairs.keys).map(\.rawValue))")
        for section in BrowseSection.allCases {
            let pair = try #require(pairs[section])
            let heading = try arm(section, in: page, from: "private func entry(_ section: BrowseSection) -> some View { switch section {",
                                  to: "enum BrowseLoad")
            let tiles = try arm(section, in: page, from: "private func tiles(_ section: BrowseSection) -> [BrowseTile] {",
                                to: "private static func title(")
            #expect(heading.contains(pair.heading), "\(section.rawValue): the heading leads elsewhere: \(heading)")
            #expect(tiles.contains(pair.tiles), "\(section.rawValue): the tiles come from elsewhere: \(tiles)")
        }
        let loader = try FetchAnswerTests.squeezedSource("Sources/ViewModels/FreeCatalogLoader.swift")
        for area in ["classical", "netlabels"] {
            let asked = try #require(loader.range(of: "popularMusic(ArchiveMusicCatalog.\(area), 12, page)"),
                                     "the \(area) lane is filled from another area")
            let filled = try #require(loader.range(of: "rows.\(area) = ", range: asked.upperBound..<loader.endIndex))
            #expect(!loader[asked.upperBound..<filled.lowerBound].contains("popularMusic("),
                    "the \(area) lane is filled from another area")
        }
    }
}
#endif
