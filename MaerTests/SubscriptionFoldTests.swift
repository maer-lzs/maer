// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The subscriptions row and its two folds: the mirror's shows and the
/// premium feeds stand in the subscriptions when their switch is on, and
/// only in their own row when it is off; the preview follows the page's
/// sort; the mirror's shows carry their glyph.
struct SubscriptionFoldTests {
    private func show(_ id: String, origin: String? = nil, newest: Double) -> PodcastShow {
        var show = PodcastShow(id: id, title: "Show \(id)", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://example.com/\(id)",
                               episodes: [PodcastEpisode(guid: "\(id)-1", title: "Ep", audioURL: "https://example.com/\(id).mp3",
                                                         pubDate: newest, duration: 600, description: nil,
                                                         imageURL: nil, chaptersURL: nil)])
        show.origin = origin
        return show
    }

    private func sections(_ fold: SubscriptionFold) -> PodcastSectionsResult {
        let shows = [show("a", newest: 3), show("m", origin: "pinchflat", newest: 2), show("p", newest: 1)]
        return PodcastSections.compute(
            shows: shows, downloadedIds: [], inboxOff: { _ in false },
            playState: { _ in .unplayed }, lastPlayed: { _ in 0 },
            isPremium: { $0.id == "p" }, fold: fold)
    }

    @Test("the rule: a show stands in the subscriptions when each of its brands is folded in")
    func theFoldRule() {
        let none = SubscriptionFold()
        #expect(none.admits(mirrored: false, premium: false))
        #expect(!none.admits(mirrored: true, premium: false))
        #expect(!none.admits(mirrored: false, premium: true))
        let both = SubscriptionFold(pinchflat: true, premium: true)
        #expect(both.admits(mirrored: true, premium: false) && both.admits(mirrored: false, premium: true))
        #expect(!SubscriptionFold(pinchflat: true).admits(mirrored: false, premium: true))
    }

    @Test("unfolded, Pinchflat and Premium stand only in their row, folded in the subscriptions and count along")
    func foldedShowsStandInTheSubscriptions() {
        let off = sections(SubscriptionFold())
        #expect(off.recentShows.map(\.show.id) == ["a"])
        #expect(off.mirroredShows.map(\.show.id) == ["m"])
        let pinchflat = sections(SubscriptionFold(pinchflat: true))
        #expect(pinchflat.recentShows.map(\.show.id) == ["a", "m"])
        #expect(pinchflat.mirroredShows.isEmpty, "the mirror's own row stands beside the folded shows")
        let premium = sections(SubscriptionFold(premium: true))
        #expect(premium.recentShows.map(\.show.id) == ["a", "p"])
        #expect(premium.mirroredShows.map(\.show.id) == ["m"])
    }

    @Test("the tab follows the switches and the sort of the page, the tile carries the Pinchflat glyph", .needsTheSources)
    func theTabFollowsTheSwitchesAndTheSort() throws {
        let tab = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PodcastsView.swift"), encoding: .utf8))
        #expect(tab.contains("shows: shows, snapshot: snapshot, sort: subscriptionSort, filter: .alle"),
                "the preview keeps its own fixed sort")
        #expect(tab.contains("let shows = premiumFolded ? [] : allShows.filter { isPremium($0) }"),
                "the premium row stands beside the folded premium shows")
        #expect(tab.contains("-\\(pinchflatFolded)-\\(premiumFolded)-\\(subscriptionSort.rawValue)\""),
                "a flipped switch or sort does not recompute the tab")
        #expect(tab.contains("RowHeading(title: \"Subscriptions\""))
        let snapshot = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastSections.swift"), encoding: .utf8))
        #expect(snapshot.contains("fold: SubscriptionFold.current"), "the live computation ignores the switches")
        let tile = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"), encoding: .utf8))
        #expect(tile.contains("if info.show.origin != nil { PinchflatGlyph() }"))
    }
}
#endif
