// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A foreign import meets a show subscribed on Audiobookshelf: the two
/// sources hold a show exclusively, so nothing is subscribed locally and
/// the summary says where the show is.
@MainActor
struct ServerHeldImportTests {
    @MainActor final class Calls {
        var hosts: [String] = []
    }

    static func serverShow(feedURL: String, title: String) -> PodcastShow {
        PodcastShow(id: "abspod:server-\(UUID().uuidString.prefix(6))", title: title,
                    author: nil, artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: "abspod:s:e1", title: "\(title) 1",
                                              audioURL: "/api/items/s/file", pubDate: 1, duration: 60)])
    }

    @Test("eine Sendung auf Audiobookshelf wird nicht lokal abonniert und nicht abgerufen, Vorschau und Ergebnis zaehlen sie, ihr Stand ohne Folge steht sichtbar als nicht zugeordnet")
    func aServerShowIsNotSubscribedHere() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let onServer = "https://server-held.example/\(run)/feed.xml"
        let other = "https://other-held.example/\(run)/feed.xml"
        subs.serverShows = { [Self.serverShow(feedURL: onServer, title: "Server Show")] }
        let calls = Calls()
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Other Show"))
        }
        let state = ForeignListeningState(feedURL: onServer, showTitle: "Server Show (source)",
                                          episodeGUID: "not-on-the-server-\(run)", enclosureURL: nil,
                                          episodeLink: nil, episodeTitle: nil,
                                          position: 30, finished: false, stampedAt: 1_000)
        let library = ForeignLibrary(feedURLs: [onServer, other], states: [state])

        let preview = ForeignImportPreview.make(
            library, subscribedFeedKeys: Set(subs.shows.map { PodcastSubscriptions.feedKey($0.feedURL) }),
            serverFeedKeys: Set(subs.serverOnlyShows().keys), feedKeyOf: PodcastSubscriptions.feedKey)
        #expect(preview.onServer == 1 && preview.alreadySubscribed == 0)

        let result = await subs.importForeignLibrary(library)
        #expect(!calls.hosts.contains("server-held.example"), "the server's show was fetched to subscribe it here")
        #expect(!subs.shows.contains { $0.feedURL == onServer }, "the server's show was subscribed here")
        #expect(result.onServer == 1 && result.onServerTitles == ["Server Show"])
        #expect(result.subscribed == 1 && result.subscribedTitles == ["Other Show"], "the other show is imported as before")
        #expect(result.unmatchedGroups.map(\.show) == ["Server Show (source)"], "the state is named, not dropped")
    }

    @Test("eine Sendung, die hier UND auf Audiobookshelf liegt, zaehlt als schon abonniert")
    func aShowHeldHereCountsAsHeld() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let both = "https://both-held.example/\(run)/feed.xml"
        subs._testFeedFetcher = { url in .show(BulkImportTests.show(url, title: "Both Show")) }
        try #require(await subs.subscribe(urlString: both, notesCloud: false))
        subs.serverShows = { [Self.serverShow(feedURL: both, title: "Both Show")] }
        #expect(subs.serverOnlyShows().isEmpty)
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [both], states: []))
        #expect(result.alreadySubscribed == 1 && result.onServer == 0)
    }
}
#endif
