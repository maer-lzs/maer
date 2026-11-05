// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every detail page with a cover builds its head through the one
/// `DetailHeader`: cover, title, lines and controls on the centre axis,
/// the facts from the leading edge.
struct DetailHeaderTests {
    /// The pages with a cover head and how often each builds it (the book
    /// page once per layout).
    static let headedPages: [(file: String, heads: Int)] = [
        ("Sources/Views/BookDetailScreen.swift", 3),
        ("Sources/Views/Music/MusicAlbumView.swift", 1),
        ("Sources/Views/Music/MusicBrowseViews.swift", 1),
        ("Sources/Views/Podcasts/PodcastShowView.swift", 1),
        ("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift", 1),
        ("Sources/Views/Radio/RadioStationDetailView.swift", 1),
        ("Sources/Views/CatalogSourcePage.swift", 1),
        ("Sources/Views/Music/MusicLibraryPages.swift", 1),
    ]

    @Test("jede Seite mit Cover-Kopf baut ihn ueber das eine Bauteil", .needsTheSources)
    func everyCoverPageTakesTheOneHead() throws {
        for page in Self.headedPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(text.components(separatedBy: "DetailHeader(").count - 1 == page.heads,
                    "\(page.file) builds its own head")
        }
        let book = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"),
                       encoding: .utf8))
        #expect(!book.contains("titleBlock(alignment:"), "the book page sets the title's alignment itself")
    }

    @Test("der Kopf steht mittig, die Fakten lesen von der fuehrenden Kante", .needsTheSources)
    func theHeadIsCentredAndTheFactsLead() throws {
        let head = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DetailHeader.swift"),
                       encoding: .utf8))
        #expect(head.components(separatedBy: ".multilineTextAlignment(.center)").count - 1 == 1)
        #expect(head.components(separatedBy: "facts()\n                    .frame(maxWidth: .infinity, alignment: .leading)").count - 1 == 1)
        #expect(!head.contains("alignment: .leading)\n                .padding(.horizontal, textInset)"),
                "title and lines lead")
        #expect(!head.contains("VStack(alignment: .leading, spacing: 14)"), "the head leads")
    }

    /// The pages whose head starts playback and how many main buttons each
    /// draws (idle and active).
    static let playingPages: [(file: String, buttons: Int)] = [
        ("Sources/Views/BookDetailScreen.swift", 2),
        ("Sources/Views/Music/MusicAlbumView.swift", 2),
        ("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift", 1),
        ("Sources/Views/Radio/RadioStationDetailView.swift", 1),
        ("Sources/Views/Music/MusicLibraryPages.swift", 1),
        // A catalog series that is an album (netlabels, 78 rpm).
        ("Sources/Views/CatalogSourcePage.swift", 1),
    ]

    @Test("ein Hauptknopf in einer Form auf jeder Seite mit Kopf", .needsTheSources)
    func oneMainButtonInOneForm() throws {
        for page in Self.playingPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(text.components(separatedBy: "DetailMainButton(").count - 1 == page.buttons,
                    "\(page.file) draws its own main button")
            #expect(!text.contains(".borderedProminent"), "\(page.file) keeps a second form")
            #expect(!text.contains("playCapsule"), "\(page.file) keeps the capsule")
        }
    }

    @Test("das Cover jeder Seite mit Kopf steht als Karte", .needsTheSources)
    func everyHeadCoverIsACard() throws {
        // The book page draws its cover in each of its three layouts: the
        // hero card itself, the other two through the book cover as a card,
        // so the progress bar stays below it (`CoverProgressBar`).
        let cards = ["Sources/Views/BookDetailScreen.swift": 1]
        for page in Self.headedPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(text.components(separatedBy: ".coverCard()").count - 1 == cards[page.file, default: 1],
                    "\(page.file) draws its cover without the card")
            if page.file.hasSuffix("BookDetailScreen.swift") {
                #expect(text.components(separatedBy: "asCard: true").count - 1 == 2)
                #expect(text.components(separatedBy: "CoverProgressBar(").count - 1 == 1, "the hero keeps a bar of its own")
            }
            #expect(!text.contains("corner: 16)") && !text.contains("radius: 14, y: 6)"),
                    "\(page.file) keeps a corner or shadow of its own")
        }
        let look = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FoldColumns.swift"), encoding: .utf8))
        #expect(look.contains("func coverCard() -> some View"), "the card can be switched off")
    }

    @Test("die Verweise eines Kopfs stehen in einer Zeile, mittig, in einer Groesse", .needsTheSources)
    func theLinksStandInOneRow() throws {
        for file in ["Sources/Views/Podcasts/PodcastShowView.swift",
                     "Sources/Views/Podcasts/PodcastEpisodeDetailView.swift",
                     "Sources/Views/Radio/RadioStationDetailView.swift"] {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8))
            #expect(text.components(separatedBy: "DetailLinkRow {").count - 1 == 1, "\(file) builds its own link row")
            #expect(!text.contains("HStack(spacing: 18)"), "\(file) keeps a link row of its own")
        }
    }

    /// The titles the files of the headed pages still set in a top bar, on
    /// their other pages, each with the pages that carry them.
    static let otherTitles: [String: (count: Int, reason: String)] = [
        "Sources/Views/BookDetailScreen.swift": (1, "the book's chapter list"),
        "Sources/Views/Music/MusicBrowseViews.swift": (2, "the artist and playlist lists"),
        "Sources/Views/CatalogSourcePage.swift": (3, "the catalog's source, popular and shelf pages"),
        "Sources/Views/Music/MusicLibraryPages.swift": (8, "the music library's list pages"),
    ]

    @Test("eine Seite mit Kopf traegt oben keinen Titel", .needsTheSources)
    func aHeadedPageHasNoTitleAbove() throws {
        for page in Self.headedPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(text.components(separatedBy: ".untitledDetailPage()").count - 1 == 1,
                    "\(page.file) names itself in the top bar")
            #expect(text.components(separatedBy: ".navigationTitle(").count - 1 == Self.otherTitles[page.file]?.count ?? 0,
                    "\(page.file) sets a title in the top bar")
        }
        #expect(!SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicBrowseViews.swift"),
                       encoding: .utf8)).contains("DetailHeader(title: nil"), "the artist goes unnamed")
        // A headed page's actions stand in its menu, editing too.
        for page in Self.headedPages {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(page.file), encoding: .utf8))
            #expect(!text.contains("EditButton()"), "\(page.file) puts editing in the top bar")
        }
    }

    /// The pages whose actions stand in the top bar and how many menus each
    /// file builds there (the music library file: the device playlist and
    /// the Jamendo page; the archive music file: an area and the shellac
    /// page; the catalogue file: a source page and a release).
    /// BESTAND OHNE EINZELGRUENDE: an inventory compared for equality, one
    /// reason for every entry (the page's one menu).
    static let pagesWithActions: [String: Int] = [
        "Sources/Views/Music/MusicAlbumView.swift": 1,
        "Sources/Views/Podcasts/PodcastShowView.swift": 1,
        "Sources/Views/Podcasts/PodcastEpisodeDetailView.swift": 1,
        "Sources/Views/Music/ArchiveMusicPages.swift": 2,
        "Sources/Views/Music/MusicLibraryPages.swift": 2,
        "Sources/Views/CatalogSourcePage.swift": 2,
    ]

    @Test("eine Seite hat einen Ort fuer ihre Handlungen: das Menue oben, kein Zeichen daneben", .needsTheSources)
    func aPageHasOnePlaceForItsActions() throws {
        var found: [String: Int] = [:]
        for file in Self.pagesWithActions.keys {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8))
            // A catalogue area page builds its menu through its draw (`catalogShuffleActions`).
            found[file] = text.components(separatedBy: ".pageActions(").count - 1
                + text.components(separatedBy: ".catalogShuffleActions").count - 1
            #expect(!text.contains("ToolbarItem(") && !text.contains("ToolbarItemGroup("),
                    "\(file) puts a control of its own in the top bar")
        }
        #expect(found == Self.pagesWithActions, "a page builds its menu another way: \(found)")
        // The menu is built in one place, with its name for VoiceOver.
        var menus: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            if SyncContractFenceTests.stripped(text).contains("Image(systemName: \"ellipsis.circle\")") { menus.append(name) }
        }
        #expect(menus == ["DetailHeader.swift"], "a page builds its own actions menu: \(menus)")
        let head = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DetailHeader.swift"),
                       encoding: .utf8))
        let place = try #require(head.components(separatedBy: "func pageActions<").last)
        #expect(place.contains("ToolbarItem(placement: .topBarTrailing) {"), "the menu left the system's place")
        #expect(place.contains(".accessibilityLabel(Text(\"Actions\"))"), "the menu has no name")
    }

    /// What the menu changes stands in the head as a state without an action
    /// of its own (favorite, stored, loading), in one place: `DetailStates`,
    /// the last of the head's lines.
    @Test("ein Zustand an einer Stelle im Kopf: Herz, Pfeil, Fortschritt, ohne eigene Handlung", .needsTheSources)
    func aStateStandsInOnePlaceOfTheHead() throws {
        var builders: [String: Int] = [:]
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            let count = SyncContractFenceTests.stripped(text).components(separatedBy: "DetailStates(").count - 1
            if count > 0 { builders[name] = count }
        }
        #expect(builders == ["MusicAlbumView.swift": 1], "the states are drawn somewhere else too: \(builders)")
        let head = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DetailHeader.swift"),
                       encoding: .utf8))
        let states = try #require(head.components(separatedBy: "struct DetailStates: View {").last)
        #expect(!states.contains("Button") && !states.contains("onTapGesture"), "a state took an action")
        #expect(states.contains("Image(systemName: \"heart.fill\")"), "the favorite is not the filled heart")
        #expect(states.contains("Image(systemName: DownloadedMark.symbol)\n                        .foregroundStyle(.secondary)"),
                "stored is not the grey arrow")
        #expect(states.contains("DownloadingRing(fraction: fraction)"), "loading shows no progress")
        // The album page puts them under its title, observed on their own,
        // and draws no state glyph of its own.
        let album = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicAlbumView.swift"),
                       encoding: .utf8))
        let lines = try #require(album.components(separatedBy: "} lines: {").last?.components(separatedBy: "} actions: {").first)
        #expect(lines.contains("AlbumHeadStates(itemId: item.id, favorite: isAlbum && starred)"),
                "the album's states left its head")
        #expect(!album.contains("\"heart.fill\"") && !album.contains("DownloadRing("), "the album draws a state of its own")
    }

    @Test("grosses Cover nur zweispaltig, einspaltig das Mass der Seite", .needsTheSources)
    func theCoverGrowsOnlyInTwoColumns() throws {
        let head = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DetailHeader.swift"),
                       encoding: .utf8))
        #expect(head.contains("DetailCoverSide.side(columnWidth: width, height: room.height, top: room.top)"))
        // Only the leading column of the two frames gives the room: the list
        // frame (show, album, playlist) and the scroll frame (artist,
        // station), each once, through the one modifier.
        let frame = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FoldColumns.swift"),
                       encoding: .utf8))
        #expect(frame.components(separatedBy: "detailHeaderRoom").count - 1 == 1)
        #expect(frame.components(separatedBy: ".leadingColumnRoom(height: geo.size.height").count - 1 == 2)
        let wide = try #require(frame.components(separatedBy: "func columns(").last?
            .components(separatedBy: "} trailing:").first)
        #expect(wide.contains(".leadingColumnRoom("), "the room stands on the list frame's leading column")
        let scroll = try #require(frame.components(separatedBy: "struct DetailScrollColumns").last?
            .components(separatedBy: "} trailing:").first)
        #expect(scroll.contains(".leadingColumnRoom("), "the room stands on the scroll frame's leading column")
        // A one-column page gives none.
        for file in ["Sources/Views/Podcasts/PodcastEpisodeDetailView.swift", "Sources/Views/CatalogSourcePage.swift",
                     "Sources/Views/Podcasts/PodcastShowView.swift", "Sources/Views/Music/MusicAlbumView.swift"] {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8))
            #expect(!text.contains("detailHeaderRoom"), "\(file) gives the room in one column")
        }
    }
}
#endif
