// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The order of the Podcasts tab: the folders under the new episodes and
/// above the subscriptions, as one row with two tiles in full and the
/// third cut at the edge; six subscriptions in the preview; Browse in the
/// form of the tab's own stock, under the heading Browse.
struct PodcastsTabOrderTests {
    static func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Fence: new episodes, then the folders, then Pinchflat, Premium and the subscriptions; the lists stay below", .needsTheSources)
    func theOrder() throws {
        let tab = try Self.source("Sources/Views/PodcastsView.swift")
        let body = tab.components(separatedBy: "var body: some View").dropFirst().first ?? ""
        let names = ["latestEpisodesSection", "foldersSection", "pinchflatGroupSection", "premiumSection",
                     "recentlyUpdatedSection", "playlistsSection"]
        let places = names.map { body.range(of: $0)?.lowerBound }
        #expect(places.allSatisfy { $0 != nil }, "a section is missing from the body: \(zip(names, places).filter { $0.1 == nil }.map(\.0))")
        let found = places.compactMap { $0 }
        #expect(found == found.sorted(), "the sections stand out of order")
    }

    @Test("the folder row: two tiles in full and the third cut at the edge on every phone width")
    func twoAndACut() {
        let edge = 16.0, spacing = 14.0
        for width in [320.0, 375.0, 393.0, 402.0, 430.0] {
            let side = Double(PodcastFolderRow.side(forWidth: width))
            let third = edge + 2 * (side + spacing)
            let shown = (width - third) / side
            #expect(edge + 2 * side + spacing <= width, "\(width): two tiles do not fit")
            #expect(shown >= 0.2 && shown <= 0.6, "\(width): the third shows \(shown) of itself")
        }
        // A cap on wide screens: the tile does not grow past it.
        #expect(PodcastFolderRow.side(forWidth: 1024) <= PodcastFolderRow.widestSide)
        #expect(PodcastFolderRow.side(forWidth: 820) <= PodcastFolderRow.widestSide)
    }

    @Test("Fence: the row's height follows the width alone; its heading leads to the page of all folders", .needsTheSources)
    func theRowAndItsPage() throws {
        let views = try Self.source("Sources/Views/Podcasts/PodcastFolderViews.swift")
        #expect(views.contains("PodcastFolderRow.side(forWidth: rowWidth)"), "the tile does not take its side from the rule")
        #expect(!views.contains("@ScaledMetric(relativeTo: .body) private var side"), "the tile still scales by itself")
        #expect(views.contains("destination: PodcastRoute.folders"), "the heading leads nowhere")
        #expect(views.contains("struct PodcastFoldersPage"), "no page of all folders")
        let routes = try Self.source("Sources/Views/Podcasts/PodcastNavigation.swift")
        #expect(routes.contains("case folders"))
    }

    @Test("the subscriptions preview shows six")
    func sixSubscriptions() {
        #expect(PodcastsView.recentShowsPreviewCap == 6)
    }

    @Test("Browse follows the tab's own stock: a podcast tab with a subscription or a server's shows has the row")
    func browseByStock() {
        func form(_ tab: MediaType, abs: Bool = false, music: Bool = false, podcasts: Bool = false, shows: Int = 0) -> TabBrowse.Form {
            TabBrowse.form(hasStock: TabBrowse.hasStock(for: tab, absSignedIn: abs, musicServer: music,
                                                        absPodcasts: podcasts, podcastShows: shows))
        }
        #expect(form(.podcasts) == .sections, "nothing of one's own: the open sections")
        #expect(form(.podcasts, shows: 1) == .row, "one subscription is stock")
        #expect(form(.podcasts, shows: 22) == .row)
        #expect(form(.podcasts, abs: true, podcasts: true) == .row, "a server's podcasts are stock without a subscription")
        #expect(form(.audiobooks, shows: 5) == .sections, "the podcasts are no stock of the books tab")
        #expect(form(.audiobooks, abs: true) == .row)
        #expect(form(.music, shows: 5) == .sections)
        #expect(form(.music, music: true) == .row)
    }

    @Test("Fence: the heading over the open sections says Browse", .needsTheSources)
    func headingSaysBrowse() throws {
        let row = try Self.source("Sources/Views/BrowseRow.swift")
        let heading = row.components(separatedBy: "struct OpenCatalogsHeading").dropFirst().first?
            .components(separatedBy: "struct ").first ?? ""
        #expect(heading.contains("Text(\"Browse\")"))
        #expect(!heading.contains("From Open Catalogs"))
    }
}
#endif
