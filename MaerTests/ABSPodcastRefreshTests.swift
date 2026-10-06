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
        #expect(Self.showsWrites(in: code) == ["shows = next"], "the shows change outside replaceShows")
        let replace = try #require(Self.body(of: "private func replaceShows(", in: code))
        #expect(replace.contains("changeToken += 1"), "replaceShows does not count the token")
        let stamps = lines.indices.filter { lines[$0].hasPrefix("lastRefreshAt = ") }
        #expect(stamps.count == 2, "the throttle is stamped \(stamps.count) times")
        for index in stamps {
            #expect(index > 0 && lines[index - 1].hasPrefix("replaceShows("), "a stamp without an adoption: \(lines[index - 1])")
        }
    }

    /// Every write to `shows`, whatever its spelling: an assignment with or
    /// without `self.`, an index assignment, `+=` and the mutating calls.
    /// A declaration is no write.
    nonisolated static func showsWrites(in code: String) -> [String] {
        code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            guard !line.hasPrefix("let ") && !line.hasPrefix("var ") && !line.contains(" var shows") else { return false }
            return line.contains(#/(?:^|[^A-Za-z0-9_.])(?:self\.)?shows(?:\s*=(?!=)|\s*\+=|\.(?:append|insert|remove\w*)\(|\[[^\]]*\]\s*=(?!=))/#)
        }
    }

    /// A refusal that can pass keeps a played mark queued; one that answers
    /// the same every time drops it (the mark stays on the device).
    @Test("die Schlange der Gehoert-Markierungen behaelt, was vorbeigeht, und laesst fallen, was immer gleich antwortet")
    func theQueueKeepsWhatCanPass() {
        for status in [nil, 401, 403, 429, 500, 503] as [Int?] {
            #expect(ABSPlayedWriteRetry.keeps(status: status), "\(String(describing: status)) dropped a mark that can pass")
        }
        for status in [400, 404, 410, 422] {
            #expect(!ABSPlayedWriteRetry.keeps(status: status), "\(status) is retried for ever")
        }
        #expect(ABSPodcastProvider.refusalStatus(APIError.http(404, "")) == 404)
        #expect(ABSPodcastProvider.refusalStatus(URLError(.notConnectedToInternet)) == nil)
    }

    /// No call to the server in the whole file ends without a line, no catch
    /// stands empty, and a failed progress pull does not count the token.
    @Test("kein Abruf der Datei endet ohne Zeile, kein catch ist leer, ein Fehlschlag zaehlt das Token nicht", .needsTheSources)
    func noCallOfTheFileEndsWithoutALine() throws {
        let code = try Self.providerCode()
        #expect(code.contains("client."), "the fence read the provider")
        #expect(!Self.swallowsAFetch(code), "a call to the server swallows its error")
        #expect(Self.emptyCatches(in: code) == 0, "a catch without a statement")
        // The pull lives in the one read path; the refresh goes through it.
        let refresh = try #require(Self.body(of: "func refreshProgress() async {", in: code))
        #expect(refresh.contains("await freshEpisodeProgress()"), "the refresh pulls on its own path")
        let progress = try #require(Self.body(of: "func freshEpisodeProgress() async -> [String: BookProgress]? {", in: code))
        let fetch = try #require(progress.range(of: "try await client.fetchPodcastEpisodeProgress()"))
        let token = try #require(progress.range(of: "changeToken += 1"))
        let failure = try #require(progress.range(of: "} catch {"))
        #expect(fetch.upperBound <= token.lowerBound && token.upperBound <= failure.lowerBound,
                "the token is counted outside the success")
        // Calibration: the empty catch of the queue as it stood, after the
        // comment was stripped, and the old forms of a write to the shows.
        #expect(Self.emptyCatches(in: "} catch {\n    \n}") == 1)
        #expect(Self.emptyCatches(in: "} catch {\n    x()\n}") == 0)
        #expect(Self.showsWrites(in: "self.shows = a\nshows.append(b)\nshows[0] = c\nshows += d\nif shows == e {}\nvar shows: [S] = []")
                == ["self.shows = a", "shows.append(b)", "shows[0] = c", "shows += d"])
    }

    /// The catch blocks in `code` that hold no statement.
    nonisolated static func emptyCatches(in code: String) -> Int {
        code.matches(of: #/catch(?:\s+let\s+\w+)?\s*\{\s*\}/#).count
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
