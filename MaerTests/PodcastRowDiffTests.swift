// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The diff names exactly the rows a change touched: a new episode moves
/// the rows of its show and no other, a changed head is one row, a removed
/// show is one removal, an unchanged stock is nothing.
struct PodcastRowDiffTests {
    private func episode(_ n: Int, show: String) -> PodcastEpisode {
        PodcastEpisode(guid: "rss:\(show):\(n)", title: "Episode \(n)", audioURL: "https://example.org/\(show)/\(n).mp3",
                       pubDate: Double(1_700_000_000_000 + n * 86_400_000), duration: 1800)
    }

    private func show(_ id: String, episodes: Int) -> PodcastShow {
        PodcastShow(id: id, title: "Show \(id)", author: nil, artworkURL: nil, description: nil,
                    feedURL: "https://example.org/\(id).xml",
                    episodes: (0..<episodes).reversed().map { episode($0, show: id) })
    }

    @Test("Unchanged is empty; everything from nothing is all rows with position")
    func unchangedIsEmptyAndFreshIsEverything() {
        let stock = [show("a", episodes: 3), show("b", episodes: 2)]
        #expect(PodcastRowDiff.compute(previous: stock, current: stock).isEmpty)
        let all = PodcastRowDiff.compute(previous: [], current: stock)
        #expect(all.showsUpserted.map(\.position) == [0, 1])
        #expect(all.showsUpserted.allSatisfy { $0.show.episodes.isEmpty }, "the head carries no episodes")
        #expect(all.episodesUpserted.count == 5)
        #expect(all.episodesUpserted.filter { $0.showId == "a" }.map(\.position) == [0, 1, 2])
        #expect(all.showsRemoved.isEmpty && all.episodesRemoved.isEmpty)
    }

    @Test("A new episode at the front moves the rows of ITS show, no other; the head stays")
    func newEpisodeMovesOnlyItsShow() {
        let before = [show("a", episodes: 3), show("b", episodes: 2)]
        var after = before
        after[0].episodes.insert(episode(9, show: "a"), at: 0)
        let diff = PodcastRowDiff.compute(previous: before, current: after)
        #expect(diff.showsUpserted.isEmpty, "the head did not change")
        #expect(diff.episodesUpserted.map(\.showId) == ["a", "a", "a", "a"])
        #expect(diff.episodesUpserted.map(\.position) == [0, 1, 2, 3])
        #expect(diff.episodesRemoved.isEmpty && diff.showsRemoved.isEmpty)
        // A changed fact on one episode, same place: one row.
        var measured = before
        measured[1].episodes[1].measuredDuration = 1234
        let one = PodcastRowDiff.compute(previous: before, current: measured)
        #expect(one.episodesUpserted.map(\.episode.guid) == ["rss:b:0"])
        #expect(one.showsUpserted.isEmpty)
    }

    @Test("Head changed = one row; show gone = one removal; episode gone = one removal; reordering moves the heads")
    func headsRemovalsAndOrder() {
        let before = [show("a", episodes: 2), show("b", episodes: 2), show("c", episodes: 1)]
        var renamed = before
        renamed[1].title = "Renamed"
        let head = PodcastRowDiff.compute(previous: before, current: renamed)
        #expect(head.showsUpserted.map(\.show.id) == ["b"])
        #expect(head.episodesUpserted.isEmpty)

        let gone = PodcastRowDiff.compute(previous: before, current: [before[0], before[2]])
        #expect(gone.showsRemoved == ["b"])
        #expect(gone.showsUpserted.map(\.show.id) == ["c"], "c moved up one position")
        #expect(gone.episodesUpserted.isEmpty, "c's episodes kept their positions")

        var trimmed = before
        trimmed[0].episodes.removeLast()
        let episodeGone = PodcastRowDiff.compute(previous: before, current: trimmed)
        #expect(episodeGone.episodesRemoved == ["rss:a:0"])
        #expect(episodeGone.episodesUpserted.isEmpty && episodeGone.showsUpserted.isEmpty)

        let reordered = PodcastRowDiff.compute(previous: before, current: [before[2], before[0], before[1]])
        #expect(reordered.showsUpserted.map(\.show.id) == ["c", "a", "b"])
        #expect(reordered.episodesUpserted.isEmpty, "episodes belong to their show, not to the list order")
    }
}
#endif
