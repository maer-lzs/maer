// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The show an episode belongs to is asked by the episode's id, which names
/// its source. Four surfaces asked the RSS provider by name instead, and an
/// Audiobookshelf episode got no show: no show badge, no premium lock.
struct PodcastShowLookupTests {
    static func show(_ id: String, feed: String, episodes: [String]) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil, description: nil, feedURL: feed,
                    episodes: episodes.map {
                        PodcastEpisode(guid: $0, title: $0, audioURL: "https://ex.example/\($0).mp3",
                                       pubDate: 1, duration: 60)
                    })
    }

    @Test("die Sendung einer Folge kommt aus der Quelle, die ihre Kennung nennt")
    func theShowOfAnEpisodeComesFromTheSourceItsIdNames() {
        let rssShow = Self.show("rss-show", feed: "https://rss.example/feed.xml", episodes: ["rss:f:1"])
        let absShow = Self.show("abs-show", feed: "https://abs.example/feed.xml", episodes: ["abspod:li_1:ep_1"])
        let subscribed: (String) -> PodcastShow? = { $0 == "rss:f:1" ? rssShow : nil }

        #expect(PodcastShowSources.show(forEpisodeId: "abspod:li_1:ep_1", subscribed: subscribed,
                                        absShows: [absShow])?.feedURL == "https://abs.example/feed.xml",
                "eine ABS-Folge findet ihre Sendung im ABS-Bestand")
        #expect(PodcastShowSources.show(forEpisodeId: "rss:f:1", subscribed: subscribed,
                                        absShows: [absShow])?.feedURL == "https://rss.example/feed.xml")
        #expect(PodcastShowSources.show(forEpisodeId: "abspod:li_9:ep_9", subscribed: subscribed,
                                        absShows: [absShow]) == nil, "eine unbekannte Folge hat keine Sendung")
    }

    /// No view asks the RSS provider by name for an episode's show any more.
    @Test("keine Ansicht fragt den RSS-Anbieter beim Namen nach der Sendung einer Folge", .needsTheSources)
    func noViewAsksTheRSSProviderByNameForAShow() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains("rssProvider.show(forEpisodeId") {
                callers.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(callers.isEmpty, "eine Ansicht fragt wieder den RSS-Anbieter beim Namen: \(callers)")
    }
}
#endif
