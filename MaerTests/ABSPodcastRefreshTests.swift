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
        let code = try Self.providerCode()
        #expect(code.contains("ABSPodcastRefreshRule.adopts(everyFetchAnswered: fetched.failures == 0"))
        for name in ["refresh()", "refreshAvailability()"] {
            let body = try #require(Self.body(of: "func \(name) async {", in: code), "the fence found \(name)")
            #expect(!Self.swallowsAFetch(body), "\(name) swallows a fetch without a line")
        }
        // Calibration: the form the refresh had before.
        #expect(Self.swallowsAFetch("guard let libraries = try? await client.fetchPodcastLibraries() else { return }"))
        #expect(!Self.swallowsAFetch("libraries = try await client.fetchPodcastLibraries()"))
    }

    /// Every change of the shows goes through `replaceShows`, which counts
    /// the token up, and the throttle is stamped only right after a run
    /// adopted the server's answer.
    @Test("jede Aenderung der Sendungen zaehlt das Token hoch, und die Drossel stellt sich nur nach einer Uebernahme", .needsTheSources)
    func everyChangeCountsTheTokenAndOnlyAnAdoptionStampsTheThrottle() throws {
        let code = try Self.providerCode()
        let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(lines.filter { $0.hasPrefix("shows = ") } == ["shows = next"], "the shows change outside replaceShows")
        let replace = try #require(Self.body(of: "private func replaceShows(", in: code))
        #expect(replace.contains("changeToken += 1"), "replaceShows does not count the token")
        let stamps = lines.indices.filter { lines[$0].hasPrefix("lastRefreshAt = ") }
        #expect(stamps.count == 2, "the throttle is stamped \(stamps.count) times")
        for index in stamps {
            #expect(index > 0 && lines[index - 1].hasPrefix("replaceShows("), "a stamp without an adoption: \(lines[index - 1])")
        }
    }

    private static func providerCode() throws -> String {
        SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ABSPodcastProvider.swift"), encoding: .utf8))
    }

    /// The body of the function whose signature starts with `signature`, up
    /// to its closing brace at the same depth.
    nonisolated static func body(of signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature) else { return nil }
        var depth = 0
        var seenOpen = false
        var index = start.lowerBound
        while index < code.endIndex {
            let char = code[index]
            if char == "{" { depth += 1; seenOpen = true }
            if char == "}" { depth -= 1 }
            index = code.index(after: index)
            if seenOpen && depth == 0 { return String(code[start.lowerBound..<index]) }
        }
        return nil
    }

    nonisolated static func swallowsAFetch(_ code: String) -> Bool {
        code.contains(#/try\?\s*await\s+client\./#)
    }
}
#endif
