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

    @Test("grosses Cover nur zweispaltig, einspaltig das Mass der Seite", .needsTheSources)
    func theCoverGrowsOnlyInTwoColumns() throws {
        let head = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/DetailHeader.swift"),
                       encoding: .utf8))
        #expect(head.contains("DetailCoverSide.side(columnWidth: width, height: room.height, top: room.top,"))
        #expect(head.contains("below = DetailCoverSide.settled(below, measured:"), "the kept height settles")
        // Only the leading column of the list frame (show, album, playlist)
        // gives the room, once, on its scroll view.
        let frame = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/FoldColumns.swift"),
                       encoding: .utf8))
        #expect(frame.components(separatedBy: "detailHeaderRoom").count - 1 == 1)
        let wide = try #require(frame.components(separatedBy: "func columns(").last?
            .components(separatedBy: "} trailing:").first)
        #expect(wide.contains("detailHeaderRoom"), "the room stands on the leading column")
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
