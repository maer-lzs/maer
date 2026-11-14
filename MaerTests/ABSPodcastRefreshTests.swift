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

    @Test("the last show deleted: every fetch answers empty, the list becomes empty")
    func theLastShowDeletedEmptiesTheList() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in [] }, detail: { _ in throw Down() })
        #expect(fetched.failures == 0 && fetched.details.isEmpty, "the precondition: every fetch answered, nothing left")
        #expect(adopts(fetched), "a deleted last show stays visible")
    }

    @Test("the list of shows fails: the state stays")
    func aFailedItemListKeepsTheShows() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in throw Down() }, detail: { Self.detail($0) })
        #expect(fetched.failures == 1 && fetched.details.isEmpty)
        #expect(!adopts(fetched), "a failed fetch emptied the shows")
    }

    @Test("all details fail: the state stays")
    func failedDetailsKeepTheShows() async {
        let fetched = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in ["a", "b", "c"] }, detail: { _ in throw Down() })
        #expect(fetched.failures == 3 && fetched.details.isEmpty)
        #expect(!adopts(fetched), "failed details emptied the shows")
    }

    @Test("something loaded, one fetch failed: what loaded counts as before")
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

    /// A run whose failures are all absences ends as an answer: the server
    /// said which shows and libraries are gone, so the device that holds
    /// them adopts it and stamps the throttle. Before, such a run adopted
    /// nothing and held nothing back, so every mount asked again after
    /// five minutes and the gone shows stood for the session.
    @Test("a round of nothing but absences is an answer: the state is adopted, never neither adopted nor blocked")
    func aRunOfAbsencesAloneIsAnAnswer() async {
        let detailsGone = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in ["a", "b"] }, detail: { _ in throw APIError.http(404, "") })
        #expect(detailsGone.failures == 0 && detailsGone.gone == 2 && detailsGone.details.isEmpty,
                "the precondition: every detail answered gone")
        #expect(adopts(detailsGone), "a run of gone shows was not adopted")
        let libraryGone = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in throw APIError.http(410, "") }, detail: { Self.detail($0) })
        #expect(libraryGone.failures == 0 && libraryGone.gone == 1, "the precondition: the list answered gone")
        #expect(adopts(libraryGone), "a run with its library gone was not adopted")
        // Gone beside a real failure: the failure holds back, as before.
        let mixed = await ABSPodcastProvider.fetchShows(
            libraryIds: ["lib"], items: { _ in ["gone", "down"] },
            detail: { id in throw id == "gone" ? APIError.http(404, "") : APIError.http(503, "") })
        #expect(mixed.failures == 1 && mixed.gone == 1 && mixed.holdsBack)
        #expect(!adopts(mixed), "a real failure beside an absence emptied the shows")
        // Every class of a run with shows held ends as an answer or a holdback.
        for fetched in [detailsGone, libraryGone, mixed] {
            #expect(adopts(fetched) || fetched.holdsBack, "a run ended in neither: \(fetched.failures) failed, \(fetched.gone) gone")
        }
    }

    /// The refresh asks the rule with the run's failures, and no fetch of the
    /// run swallows its error any more.
    @Test("the refresh asks the rule with the failed fetches", .needsTheSources)
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
    @Test("every change of the shows counts the token up, and the throttle resets only after an adoption", .needsTheSources)
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

    /// A refresh that failed holds the implicit callers for the holdback:
    /// the loops of gpodder, Pinchflat and the cloud adoption ask per feed,
    /// and an unread server was asked again for every one of them. Which
    /// failures earn the holdback is one question at one place
    /// (`FetchHoldback.starts`), asked by both stamps: a show deleted on the
    /// server (404) is a finding, a cancellation is no failure.
    @Test("after a failed run no implicit caller asks before the block period ends; a rule says which errors block", .needsTheSources)
    func aFailedRunHoldsTheImplicitCallers() async throws {
        // The classes, through the fetch itself: a deleted show holds
        // nothing, a failing server holds, a cancellation holds nothing.
        func run(_ error: Error) async -> ABSPodcastProvider.FetchedShows {
            await ABSPodcastProvider.fetchShows(libraryIds: ["lib"], items: { _ in ["gone"] },
                                                detail: { _ in throw error })
        }
        let deleted = await run(APIError.http(404, ""))
        #expect(deleted.failures == 0 && deleted.gone == 1 && !deleted.holdsBack,
                "a show deleted on the server counted as a failure or started a holdback")
        let failing = await run(APIError.http(503, ""))
        #expect(failing.failures == 1 && failing.holdsBack, "a failing server started no holdback")
        let cancelled = await run(CancellationError())
        #expect(!cancelled.holdsBack, "a cancellation started a holdback")
        let listDown = await ABSPodcastProvider.fetchShows(libraryIds: ["lib"], items: { _ in throw Down() },
                                                           detail: { _ in Self.detail("x") })
        #expect(listDown.holdsBack, "a failed item list started no holdback")
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: nil, failedAt: nil, now: now, maxAge: 300))
        #expect(!ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: nil, failedAt: now.addingTimeInterval(-60), now: now, maxAge: 300),
                "a run that failed a minute ago is asked again")
        #expect(ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: nil, failedAt: now.addingTimeInterval(-FetchHoldback.seconds), now: now, maxAge: 300))
        #expect(!ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: now.addingTimeInterval(-60), failedAt: nil, now: now, maxAge: 300))
        // Wiring: the throttle asks the rule with the failure, both ways a
        // run keeps the stock set it, an adoption clears it.
        let code = try Self.providerCode()
        let stale = try #require(Self.body(of: "func refreshIfStale(", in: code))
        #expect(stale.contains("ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: lastRefreshAt, failedAt: failedAt"))
        let refresh = try #require(Self.body(of: "func refresh() async {", in: code))
        #expect(refresh.contains("if FetchHoldback.starts(after: error) { failedAt = Date() }"), "a failed library list holds nothing")
        #expect(refresh.contains("} else if fetched.holdsBack {"), "the second stamp asks its own question instead of the rule's")
        #expect(refresh.contains("failedAt = nil"), "an adoption keeps the holdback of a run before")
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
    @Test("the queue of played marks keeps what passes by and drops what always answers the same")
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
    @Test("no fetch of the file ends without a line, no catch is empty, a failure does not count the token", .needsTheSources)
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

    /// A write to the server from a stored entry takes the one form
    /// (`ForeignServerProgress.write`), the history push included, and the
    /// shows are only replaced together with their episode handles.
    @Test("a write to the server from a saved state takes the one source form, and shows are set only with their handles", .needsTheSources)
    func oneFormOfAWriteAndShowsWithTheirHandles() throws {
        let code = try Self.providerCode()
        #expect(code.contains("client.updateEpisodeProgress("), "the fence read the provider")
        #expect(Self.ownWriteForms(in: code) == 0, "a second form of a write from a stored entry")
        let push = try #require(Self.body(of: "func pushLocalHistoryToServer() async {", in: code))
        #expect(push.contains("ForeignServerProgress.write("), "the history push writes without the one form")
        #expect(Self.replacesWithoutHandles(in: code) == 0, "shows replaced without naming their handles")
        // Calibration: the push as it stood, a call without handles, and the
        // signature with its default.
        #expect(Self.ownWriteForms(in: "let f = ProgressMark.reachedEnd(stored: arr, currentDuration: d)") == 1)
        #expect(Self.replacesWithoutHandles(in: """
            replaceShows([], absToRSS: [:], rssToABS: [:])
            replaceShows(a, absToRSS: b, rssToABS: c, handles: d)
            private func replaceShows(_ next: [S], absToRSS: [S: S], rssToABS: [S: S],
                                      handles: [S: H] = [:]) {
            """) == 2)
    }

    /// The places in `code` that turn a stored entry into a write themselves.
    nonisolated static func ownWriteForms(in code: String) -> Int {
        code.matches(of: #/reachedEnd\(\s*stored:/#).count
    }

    /// Calls of `replaceShows` that leave the handles out, and a default
    /// that would let them.
    nonisolated static func replacesWithoutHandles(in code: String) -> Int {
        code.matches(of: #/replaceShows\([^)]*\)/#).filter { match in
            let text = String(match.output)
            return !text.contains("handles:") || text.contains("= [:]")
        }.count
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
