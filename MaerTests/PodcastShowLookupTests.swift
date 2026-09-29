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

    /// The cases live in `Fixtures/Shared/abos/show-lookup.json`, read by
    /// Swift and Kotlin alike: the show of an episode comes from the source
    /// its id names, an unknown episode has none.
    nonisolated static let lookup = SharedCases.cases("show-lookup")

    static func show(_ value: JSONValue) -> PodcastShow {
        show(value["id"]?.string ?? "", feed: value["feedURL"]?.string ?? "", episodes: value["episodes"]?.strings ?? [])
    }

    @Test("gemeinsame Faelle: show-lookup traegt drei Faelle")
    func lookupCasesLoaded() {
        #expect(Self.lookup.count == 3)
    }

    @Test("gemeinsame Faelle: die Sendung einer Folge kommt je Fall aus der Quelle, die die Datei nennt", arguments: lookup)
    func theShowOfAnEpisodeComesFromTheSourceItsIdNames(_ c: SharedCase) throws {
        let input = try c.value("input")
        let subscribed = (input["subscribed"]?.object ?? [:]).mapValues(Self.show)
        let absShows = (input["absShows"]?.array ?? []).map(Self.show)
        let found = PodcastShowSources.show(forEpisodeId: try #require(input["episodeId"]?.string),
                                            subscribed: { subscribed[$0] }, absShows: absShows)
        #expect(found?.feedURL == c["expect"]?.string, "\(c.slug)")
    }

    /// No view asks the RSS provider by name for an episode's show, nor for
    /// the episodes of a show: the show carries them, and the mapping is pure.
    @Test("keine Ansicht fragt den RSS-Anbieter beim Namen nach einer Sendung oder ihren Folgen", .needsTheSources)
    func noViewAsksTheRSSProviderByNameForAShow() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && (line.contains("rssProvider.show(forEpisodeId") || line.contains("rssProvider.showItems(")) {
                callers.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(callers.isEmpty, "eine Ansicht fragt wieder den RSS-Anbieter beim Namen: \(callers)")
    }
}
#endif
