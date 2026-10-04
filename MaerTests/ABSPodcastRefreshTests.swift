// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One refresh of the server's podcast shows: an empty answer after the
/// last show was deleted replaces the list; an empty answer because a fetch
/// failed keeps it.
struct ABSPodcastRefreshTests {
    nonisolated private struct Down: Error {}

    nonisolated private static func detail(_ id: String) -> LibraryItemDetail {
        LibraryItemDetail(id: id, media: LibraryItemMedia(metadata: nil, duration: nil, chapters: nil, tracks: nil),
                          userMediaProgress: nil)
    }

    /// What the provider decides from one run, for a device that holds shows.
    private func adopts(_ fetched: ABSPodcastProvider.FetchedShows) -> Bool {
        ABSPodcastRefreshRule.adopts(everyFetchAnswered: fetched.failures == 0,
                                     loadedAny: !fetched.details.isEmpty, holdsShows: true)
    }

    @Test("die letzte Sendung geloescht: jeder Abruf antwortet leer, die Liste wird leer")
    func theLastShowDeletedEmptiesTheList() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in [] }, detail: { _ in throw Down() })
        #expect(fetched.failures == 0 && fetched.details.isEmpty, "the precondition: every fetch answered, nothing left")
        #expect(adopts(fetched), "a deleted last show stays visible")
    }

    @Test("die Liste der Sendungen scheitert: der Stand bleibt")
    func aFailedItemListKeepsTheShows() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in throw Down() }, detail: { Self.detail($0) })
        #expect(fetched.failures == 1 && fetched.details.isEmpty)
        #expect(!adopts(fetched), "a failed fetch emptied the shows")
    }

    @Test("alle Details scheitern: der Stand bleibt")
    func failedDetailsKeepTheShows() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in ["a", "b", "c"] }, detail: { _ in throw Down() })
        #expect(fetched.failures == 3 && fetched.details.isEmpty)
        #expect(!adopts(fetched), "failed details emptied the shows")
    }

    @Test("etwas geladen, ein Abruf gescheitert: das Geladene gilt wie bisher")
    func aPartialRunTakesWhatCame() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["one", "two"],
            items: { library in if library == "two" { throw Down() }; return ["a", "b"] },
            detail: { id in if id == "b" { throw Down() }; return Self.detail(id) })
        #expect(fetched.failures == 2 && fetched.details.map(\.id) == ["a"])
        #expect(adopts(fetched))
        #expect(ABSPodcastRefreshRule.adopts(everyFetchAnswered: false, loadedAny: false, holdsShows: false),
                "a device without shows takes even an empty failed run, as before")
    }

    /// The refresh asks the rule with the run's failures, and no fetch of the
    /// run swallows its error any more.
    @Test("die Aktualisierung fragt die Regel mit den gescheiterten Abrufen", .needsTheSources)
    func theRefreshAsksTheRule() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ABSPodcastProvider.swift"), encoding: .utf8))
        #expect(code.contains("ABSPodcastRefreshRule.adopts(everyFetchAnswered: fetched.failures == 0"))
        #expect(!code.contains("try? await client.fetchLibraryItems"), "an item list fails silently")
        #expect(!code.contains("try? await client.fetchItemDetail"), "a detail fails silently")
    }
}
#endif
