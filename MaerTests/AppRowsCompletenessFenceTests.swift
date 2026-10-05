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
        "home.recommendations": [Site(owner: "HomeView", name: "discoverSection")],
        "home.discoverBooks": [Site(owner: "HomeView", name: "discoverAudiobooksSection")],
        "home.discoverMusic": [Site(owner: "HomeView", name: "body", anchor: "FreeCatalogRows(")],
        "home.rediscover": [Site(owner: "HomeView", name: "rediscoverSection")],
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

        "music.listenAgain": [Site(owner: "MusicView", name: "content", anchor: "\"Listen Again\"")],
        "music.netlabels": [Site(owner: "MusicView", name: "content", anchor: "\"Netlabels\"")],
        "music.oldRecords": [Site(owner: "MusicView", name: "content", anchor: "ShellacSection(")],
        "music.jamendo": [Site(owner: "MusicView", name: "content", anchor: "\"Free Music (Jamendo)\"")],
        "music.playlists": [Site(owner: "MusicView", name: "playlistRow")],
        // One shelf function draws both; the calls are counted below.
        "music.recentlyPlayed": [Site(owner: "MusicView", name: "shelf")],
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
        pattern: #"RowHeading|\.font\(\.title3\)\.bold\(\)|LatestEpisodesGrid\(|ShellacSection\(|FreeCatalogRows\(|RadioFeaturedCardRow\(|RadioCardRow\("#)
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
        // The one shelf draws exactly the two rows that name it.
        let music = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicView.swift"), encoding: .utf8))
        #expect(music.components(separatedBy: "shelf(\"").count == 3)
        #expect(music.contains("shelf(\"Recently Played\"") && music.contains("shelf(\"Recently Added\""))
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
