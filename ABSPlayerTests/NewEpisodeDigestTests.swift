// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import ABSPlayer

/// One message per refresh run. The three cases and where each one leads.
///
/// Measured before the change: the refresh bundled per SHOW and posted in a
/// loop, so five shows with new episodes meant five messages and five sounds.
struct NewEpisodeDigestTests {
    private func show(_ title: String, count: Int, newest: String = "",
                      feed: String = "https://feed") -> NewEpisodeDigest.Show {
        NewEpisodeDigest.Show(title: title, feedURL: feed,
                              newCount: count, newestEpisodeTitle: newest)
    }

    @Test("one new episode is worth naming")
    func singleEpisode() throws {
        let message = try #require(NewEpisodeDigest.message(
            for: [show("Lage der Nation", count: 1, newest: "LdN400")]))
        #expect(message.title == "Lage der Nation")
        #expect(message.body == "LdN400")
        #expect(message.target == .show(feedURL: "https://feed"))
    }

    @Test("several episodes of one show are counted under its name")
    func severalEpisodesOneShow() throws {
        let message = try #require(NewEpisodeDigest.message(
            for: [show("Lage der Nation", count: 3, newest: "LdN400")]))
        #expect(message.title == "Lage der Nation")
        #expect(message.body.contains("3"))
        // Still ONE show, so the target stays that show. The count does not
        // turn it into a collection.
        #expect(message.target == .show(feedURL: "https://feed"))
    }

    @Test("several shows can only be counted — and lead to the list")
    func severalShows() throws {
        let message = try #require(NewEpisodeDigest.message(for: [
            show("A", count: 2, feed: "https://a"),
            show("B", count: 1, feed: "https://b"),
            show("C", count: 4, feed: "https://c"),
        ]))
        // 7 episodes in 3 shows. Both numbers are in the line.
        #expect(message.body.contains("7"))
        #expect(message.body.contains("3"))
        #expect(message.target == .latestEpisodes)
    }

    @Test("nothing to say means no message")
    func nothingToSay() {
        #expect(NewEpisodeDigest.message(for: []) == nil)
        // A show without new episodes must not produce one either.
        #expect(NewEpisodeDigest.message(for: [show("A", count: 0)]) == nil)
    }

    /// Shows without news do not count towards the "several shows" case.
    /// Otherwise one new episode would be announced as a collection.
    @Test("empty shows drop out of the decision")
    func emptyShowsDropOut() throws {
        let message = try #require(NewEpisodeDigest.message(for: [
            show("Quiet", count: 0, feed: "https://quiet"),
            show("Loud", count: 1, newest: "Episode 1", feed: "https://loud"),
        ]))
        #expect(message.title == "Loud")
        #expect(message.target == .show(feedURL: "https://loud"))
    }
}
