// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every row rendered at a tab root stands in `AppRows`, with a switch or a
/// named reason, and every entry of `AppRows` is rendered or named as an
/// asker that is no row. Read at the code in both directions: a heading at
/// a tab root without an entry is red, and so is an entry whose place no
/// longer draws a heading.
struct AppRowsCompletenessFenceTests {
    /// Where a row is drawn: the tab root's struct, the property or
    /// function inside it, and, where one declaration draws several rows,
    /// a literal on the heading line or the line above it.
    struct Site: Hashable, CustomStringConvertible {
        let owner: String
        let name: String
        var anchor: String? = nil
        var description: String { "\(owner).\(name)" + (anchor.map { " [\($0)]" } ?? "") }
    }

    /// The tab roots, and the catalog page that signed out IS the
    /// audiobooks tab.
    static let roots: [(file: String, owner: String)] = [
        ("Sources/Views/HomeView.swift", "HomeView"),
        ("Sources/Views/LibraryView.swift", "LibraryView"),
        ("Sources/Views/FreeAudiobooksPage.swift", "FreeAudiobooksPage"),
        ("Sources/Views/Music/MusicView.swift", "MusicView"),
        ("Sources/Views/PodcastsView.swift", "PodcastsView"),
        ("Sources/Views/Radio/RadioView.swift", "RadioView"),
    ]

    static let sites: [String: [Site]] = [
        "home.continue": [Site(owner: "HomeView", name: "continueSection")],
        "home.upNext": [Site(owner: "HomeView", name: "upNextSection")],
        "home.listenAgain": [Site(owner: "HomeView", name: "recentlyPlayedSection")],
        "home.latestEpisodes": [Site(owner: "HomeView", name: "latestEpisodesSection")],
        "home.rediscover": [Site(owner: "HomeView", name: "rediscoverSection")],
        // The three shares of the one Browse row.
        "home.recommendations": [Site(owner: "HomeView", name: "browseSection")],
        "home.discoverMusic": [Site(owner: "HomeView", name: "browseSection")],
        "home.discoverBooks": [Site(owner: "HomeView", name: "browseSection")],
        "home.recentlyAdded": [Site(owner: "HomeView", name: "recentlyAddedSection")],

        "books.catalog": [Site(owner: "LibraryView", name: "freeAudiobooksSection"),
                          Site(owner: "FreeAudiobooksPage", name: "feedSection"),
                          Site(owner: "FreeAudiobooksPage", name: "tileSection"),
                          Site(owner: "FreeAudiobooksPage", name: "failureLine")],
        "books.charts": [Site(owner: "FreeAudiobooksPage", name: "chartsSection")],
        "books.localFiles": [Site(owner: "LibraryView", name: "localFilesSection")],
        "books.continue": [Site(owner: "LibraryView", name: "continueFeaturedSection")],
        "books.recentlyAdded": [Site(owner: "LibraryView", name: "recentlyAddedGrid")],
        "books.downloaded": [Site(owner: "LibraryView", name: "downloadedSection")],
        "books.allBooks": [Site(owner: "LibraryView", name: "allBooksSection")],

        "music.netlabels": [Site(owner: "MusicView", name: "content", anchor: "\"Netlabels\"")],
        "music.oldRecords": [Site(owner: "MusicView", name: "content", anchor: "ShellacSection(")],
        "music.jamendo": [Site(owner: "MusicView", name: "content", anchor: "\"Free Music (Jamendo)\"")],
        "music.playlists": [Site(owner: "MusicView", name: "playlistRow")],
        "music.recentlyPlayed": [Site(owner: "MusicView", name: "recentlyPlayedRow")],
        // The shelf function draws only this row now; its call is counted below.
        "music.recentlyAdded": [Site(owner: "MusicView", name: "shelf")],

        "podcasts.continue": [Site(owner: "PodcastsView", name: "nextUpSection")],
        "podcasts.radioPlays": [Site(owner: "PodcastsView", name: "hoerspieleSection")],
        "podcasts.recommended": [Site(owner: "PodcastsView", name: "recommendationsSection")],
        "podcasts.subscriptions": [Site(owner: "PodcastsView", name: "recentlyUpdatedSection")],
        "podcasts.latestEpisodes": [Site(owner: "PodcastsView", name: "latestEpisodesSection")],
        "podcasts.coListened": [Site(owner: "PodcastsView", name: "coListenedSection")],
        "podcasts.pinchflat": [Site(owner: "PodcastsView", name: "pinchflatGroupSection")],
        "podcasts.notFollowed": [Site(owner: "PodcastsView", name: "needsSignInSection")],
        "podcasts.premium": [Site(owner: "PodcastsView", name: "premiumSection")],
        "podcasts.downloaded": [Site(owner: "PodcastsView", name: "downloadedShelf")],

        "radio.myStations": [Site(owner: "RadioView", name: "body", anchor: "RadioFeaturedCardRow(")],
        "radio.catalog": [Site(owner: "RadioView", name: "body", anchor: "RowHeading<RadioRoute>("),
                          Site(owner: "RadioView", name: "genreSection"),
                          Site(owner: "RadioView", name: "regionSection")],
        "radio.recentlyPlayed": [Site(owner: "RadioView", name: "cardRow")],
    ]

    /// Entries that ask a service without drawing a row of their own.
    static let askers: Set<String> = ["books.search", "podcasts.search", "radio.search", "radio.stationLogos"]

    /// Headings at a tab root that head no row, each with its reason.
    static let notRows: [Site: String] = [
        Site(owner: "PodcastsView", name: "body", anchor: "\"No podcasts yet\""):
            "the empty state's way to add a first show",
    ]

    /// What heads a row: the shared heading, a heading set by hand, and
    /// the parts that carry their own heading.
    static let heading = try! NSRegularExpression(
        pattern: #"RowHeading|\.font\(\.title3\)\.bold\(\)|LatestEpisodesGrid\(|ShellacSection\(|FreeCatalogRows\(|RadioFeaturedCardRow\(|RadioCardRow\(|BrowseRow\("#)
    static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|static|nonisolated)\s+)*(?:var|func)\s+(\w+)"#)

    /// One heading found at a tab root: its owner, its declaration, and
    /// the line with the one above it, for the anchors.
    struct Found {
        let owner: String
        let name: String
        let lines: String
        let number: Int
    }

    /// The headings inside the root struct and its extensions, each with
    /// the nearest declaration above it.
    static func headings(in code: String, owner: String) -> [Found] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inside = false
        var current = "?"
        var found: [Found] = []
        for (index, line) in lines.enumerated() {
            if !line.hasPrefix(" "), line.range(of: #"^(?:\w+\s+)*(?:struct|extension)\s+\#(owner)\b"#,
                                               options: .regularExpression) != nil {
                inside = true
                continue
            }
            if inside, line == "}" { inside = false; continue }
            guard inside else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = declaration.firstMatch(in: line, range: range),
               let name = Range(match.range(at: 1), in: line) {
                current = String(line[name])
            }
            let code = line.components(separatedBy: "//").first ?? line
            if heading.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                let above = index > 0 ? lines[index - 1] : ""
                found.append(Found(owner: owner, name: current, lines: above + "\n" + line, number: index + 1))
            }
        }
        return found
    }

    static func matches(_ site: Site, _ found: Found) -> Bool {
        site.owner == found.owner && site.name == found.name
            && (site.anchor.map { found.lines.contains($0) } ?? true)
    }

    static func allHeadings() throws -> [Found] {
        try roots.flatMap { root in
            headings(in: try String(contentsOf: SourceTree.root.appendingPathComponent(root.file), encoding: .utf8),
                     owner: root.owner)
        }
    }

    @Test("jede Ueberschrift an einer Reiter-Wurzel gehoert zu einer Reihe der Liste", .needsTheSources)
    func everyRenderedRowIsListed() throws {
        let found = try Self.allHeadings()
        #expect(found.count > 30, "the reading found only \(found.count) headings")
        let known = Self.sites.values.flatMap { $0 } + Array(Self.notRows.keys)
        let orphans = found.filter { heading in !known.contains { Self.matches($0, heading) } }
        #expect(orphans.isEmpty, "rows drawn without an entry in AppRows: \(orphans.map { "\($0.owner).\($0.name) line \($0.number)" })")
        let keys = Set(AppRows.all.map(\.key))
        #expect(Set(Self.sites.keys).subtracting(keys).isEmpty, "places for rows AppRows does not know")
    }

    @Test("jede Reihe der Liste wird gezeichnet oder ist ein benannter Nachfrager", .needsTheSources)
    func everyListedRowIsRendered() throws {
        let found = try Self.allHeadings()
        let keys = Set(AppRows.all.map(\.key))
        #expect(keys.subtracting(Self.sites.keys).subtracting(Self.askers).isEmpty,
                "entries with no place: \(keys.subtracting(Self.sites.keys).subtracting(Self.askers).sorted())")
        #expect(Self.askers.isSubset(of: keys))
        for (key, places) in Self.sites {
            for site in places {
                #expect(found.contains { Self.matches(site, $0) }, "\(key): \(site) draws no heading any more")
            }
        }
        for site in Self.notRows.keys {
            #expect(found.contains { Self.matches(site, $0) }, "\(site) is gone; take it out of the stock")
        }
        // The one shelf draws exactly the row that names it.
        let music = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicView.swift"), encoding: .utf8))
        #expect(music.components(separatedBy: "shelf(\"").count == 2)
        #expect(music.contains("shelf(\"Recently Added\""))
        let radio = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Radio/RadioView.swift"), encoding: .utf8))
        #expect(radio.components(separatedBy: "cardRow(title: String(localized:").count == 2, "the recents card row draws a second row")
    }

    @Test("ohne Schalter nennt jede Reihe ihren Grund, und jede Quelle loest auf")
    func everyFixedEntryNamesItsReasonAndEverySourceResolves() {
        for row in AppRows.all {
            #expect(row.toggleable == (row.fixed == nil), "\(row.key): a switch and a reason, or neither")
            for key in row.sourceKeys {
                #expect(ExternalSources.source(key: key) != nil, "\(row.key) draws from \(key), which is no source")
            }
        }
        for key in Self.askers {
            let fixed = AppRows.row(key: key)?.fixed
            #expect(fixed == .onSearch || fixed == .stationLogos, "\(key) is an asker and says \(String(describing: fixed))")
        }
        #expect(AppRows.all.filter { $0.fixed == .onSearch || $0.fixed == .stationLogos }.allSatisfy { Self.askers.contains($0.key) })
        #expect(Set(AppRows.all.map(\.key)).count == AppRows.all.count, "a key stands twice")
    }

    /// The order of the tabs: per tab, the calls at the root in the
    /// order they must render, each with the row it draws (nil for what
    /// is no row: a notice, the library deck, a branch). Read in sequence,
    /// each one after the one before.
    struct Order {
        let file: String
        let from: String
        let steps: [(call: String, key: String?)]
    }

    static let orders: [Order] = [
        Order(file: "Sources/Views/HomeView.swift",
              from: "LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {",
              steps: [("continueSection", "home.continue"), ("upNextSection", "home.upNext"),
                      ("recentlyPlayedSection", "home.listenAgain"), ("latestEpisodesSection", "home.latestEpisodes"),
                      ("if recentlyAddedRowVisible { recentlyAddedSection }", "home.recentlyAdded"),
                      ("if rediscoverRowVisible { rediscoverSection }", "home.rediscover"),
                      ("if browseVisible { browseSection }", "home.recommendations")]),
        Order(file: "Sources/Views/LibraryView.swift",
              from: "private var content: some View {",
              steps: [("AbsSessionStateBanner()", nil), ("continueFeaturedSection", "books.continue"),
                      ("if !AppSession.shared.authViewModel.isLoggedIn {", nil),
                      ("localFilesSection", "books.localFiles"), ("stockSections", nil),
                      ("allBooksSection", "books.allBooks"),
                      ("FreeAudiobooksPage(playerCoordinator: playerCoordinator, embedded: true)", "books.catalog"),
                      ("} else {", nil), ("stockSections", nil),
                      ("librarySectionState", nil), ("allBooksSection", "books.allBooks"),
                      ("freeAudiobooksSection", "books.catalog"), ("bookTabDeck", nil), ("historySection", nil)]),
        Order(file: "Sources/Views/LibraryView.swift",
              from: "private var stockSections: some View {",
              steps: [("downloadedSection", "books.downloaded"), ("recentlyAddedGrid", "books.recentlyAdded")]),
        Order(file: "Sources/Views/Music/MusicView.swift",
              from: "private var content: some View {",
              steps: [("playlistRow", "music.playlists"), ("vm.errorText", nil),
                      ("recentlyPlayedRow", "music.recentlyPlayed"), ("libraryList", nil),
                      ("shelf(\"Recently Added\"", "music.recentlyAdded"), ("\"Netlabels\"", "music.netlabels"),
                      ("ShellacSection(", "music.oldRecords"), ("\"Free Music (Jamendo)\"", "music.jamendo"),
                      ("ListeningHistoryRow(route: MusicRoute.history", nil)]),
        Order(file: "Sources/Views/PodcastsView.swift",
              from: "VStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {",
              steps: [("nextUpSection", "podcasts.continue"), ("needsSignInSection", "podcasts.notFollowed"),
                      ("latestEpisodesSection", "podcasts.latestEpisodes"), ("pinchflatGroupSection", "podcasts.pinchflat"),
                      ("premiumSection", "podcasts.premium"), ("recentlyUpdatedSection", "podcasts.subscriptions"),
                      ("downloadedShelf", "podcasts.downloaded"), ("coListenedSection", "podcasts.coListened"),
                      ("if recommendedRowVisible { recommendationsSection }", "podcasts.recommended"),
                      ("hoerspieleSection", "podcasts.radioPlays"), ("historyRow", nil)]),
        Order(file: "Sources/Views/Radio/RadioView.swift",
              from: "LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {",
              steps: [("RadioFeaturedCardRow(", "radio.myStations"),
                      ("cardRow(title: String(localized: \"Recently Played\")", "radio.recentlyPlayed"),
                      ("if showsPopular {", "radio.catalog"), ("if catalogRowVisible { regionSection }", "radio.catalog"),
                      ("genreSection", "radio.catalog")]),
    ]

    /// Where each call stands, searched in sequence from `from`; nil for a
    /// call that does not follow the one before it.
    static func sequence(_ order: Order, in code: String) -> [Int?] {
        guard let start = code.range(of: order.from) else { return order.steps.map { _ in nil } }
        var cursor = start.upperBound
        return order.steps.map { step in
            guard let hit = code.range(of: step.call, range: cursor..<code.endIndex) else { return nil }
            cursor = hit.upperBound
            return code.distance(from: code.startIndex, to: hit.lowerBound)
        }
    }

    @Test("jeder Reiter steht in seiner Reihenfolge, und die Liste der Reihen auch", .needsTheSources)
    func everyTabStandsInItsOrder() throws {
        for order in Self.orders {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(order.file), encoding: .utf8))
            let found = Self.sequence(order, in: code)
            for (step, place) in zip(order.steps, found) {
                #expect(place != nil, "\(order.file): \(step.call) does not follow the call before it")
            }
            // The list of rows reads in the same order, so the rows page
            // shows each tab as it stands.
            var keys: [String] = []
            for key in order.steps.compactMap({ $0.key }) where keys.last != key { keys.append(key) }
            let listed = AppRows.all.map(\.key).filter { keys.contains($0) }
            var expected: [String] = []
            for key in keys where !expected.contains(key) { expected.append(key) }
            #expect(listed == expected, "\(order.file): AppRows lists \(listed), the tab draws \(expected)")
        }
        let probe = Order(file: "", from: "start", steps: [("a", nil), ("b", nil)])
        #expect(Self.sequence(probe, in: "start a b") .allSatisfy { $0 != nil })
        #expect(Self.sequence(probe, in: "start b a").last! == nil, "the reading sees no order")
    }

    @Test("die Lesung selbst: Ueberschrift, Deklaration, Anker und Bereich")
    func theReadingItself() {
        let code = """
        struct Other: View {
            var body: some View { RowHeading.plain("x") }
        }
        struct Root: View {
            private var one: some View {
                RowHeading.plain("One")
            }
            // RowHeading in a comment counts not
            func two() -> some View {
                Text("Two")
                    .font(.title3).bold()
            }
        }
        """
        let found = Self.headings(in: code, owner: "Root")
        #expect(found.map(\.name) == ["one", "two"])
        #expect(Self.matches(Site(owner: "Root", name: "two", anchor: "\"Two\""), found[1]))
        #expect(!Self.matches(Site(owner: "Root", name: "two", anchor: "\"One\""), found[1]))
    }
}
#endif
