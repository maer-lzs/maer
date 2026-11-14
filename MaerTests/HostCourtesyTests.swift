// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Courtesy toward third-party services: at most four requests
/// at once per host, MusicBrainz and the Cover Art Archive together
/// at most one per second, and after 429 or 503 the whole host rests as
/// long as it asks, an own server too.
struct HostCourtesyTests {
    // MARK: - The rule, pure

    @Test("Rule: MusicBrainz and the Cover Art Archive are one group, Wikidata and Commons a second, every other host its own")
    func groups() {
        #expect(HostCourtesyRule.group(of: "musicbrainz.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "coverartarchive.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "beta.MusicBrainz.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "www.wikidata.org") == "wikimedia")
        #expect(HostCourtesyRule.group(of: "commons.wikimedia.org") == "wikimedia")
        #expect(HostCourtesyRule.group(of: "notmusicbrainz.org") == "notmusicbrainz.org", "a suffix is a domain, not a string")
        #expect(HostCourtesyRule.group(of: "archive.org") == "archive.org")
    }

    @Test("Rule: third-party four at once, MusicBrainz one per second, Wikimedia one after the other, own servers without a cap")
    func allowances() {
        #expect(HostCourtesyRule.allowance(group: "archive.org", isOwnServer: false)
                == .init(concurrent: 4, spacing: nil))
        #expect(HostCourtesyRule.allowance(group: "musicbrainz", isOwnServer: false)
                == .init(concurrent: 1, spacing: .seconds(1)))
        #expect(HostCourtesyRule.allowance(group: "wikimedia", isOwnServer: false)
                == .init(concurrent: 1, spacing: nil))
        #expect(HostCourtesyRule.allowance(group: "abs.home", isOwnServer: true)
                == .init(concurrent: nil, spacing: nil))
        #expect(HostCourtesyRule.asksToRest(status: 429) && HostCourtesyRule.asksToRest(status: 503))
        #expect(!HostCourtesyRule.asksToRest(status: 500) && !HostCourtesyRule.asksToRest(status: 404))
    }

    @Test("Rule: Retry-After in seconds or as a date, otherwise 2, 4, 8 up to 60 seconds, at most one hour")
    func rests() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HostCourtesyRule.rest(retryAfter: "120", restsInARow: 0, now: now) == .seconds(120))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let inThirty = formatter.string(from: now.addingTimeInterval(30))
        #expect(HostCourtesyRule.rest(retryAfter: inThirty, restsInARow: 0, now: now) == .seconds(30))
        #expect(HostCourtesyRule.rest(retryAfter: "999999", restsInARow: 0, now: now) == .seconds(3600))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 0, now: now) == .seconds(2))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 1, now: now) == .seconds(4))
        #expect(HostCourtesyRule.rest(retryAfter: "soon", restsInARow: 2, now: now) == .seconds(8))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 9, now: now) == .seconds(60))
    }

    @Test("Rule: only a refused connection lets the host rest, 30 seconds, within the wait limit")
    func onlyARefusalRests() {
        #expect(HostCourtesyRule.isRefusal(URLError(.cannotConnectToHost)))
        // A dropped connection (-1005) also comes from the device's network
        // change; timeout, cancellation, foreign errors say nothing
        // about an overrun host.
        #expect(!HostCourtesyRule.isRefusal(URLError(.networkConnectionLost)))
        #expect(HostCourtesyRule.restsAfterRefusal(isOwnServer: false))
        #expect(!HostCourtesyRule.restsAfterRefusal(isOwnServer: true))
        #expect(!HostCourtesyRule.isRefusal(URLError(.timedOut)))
        #expect(!HostCourtesyRule.isRefusal(URLError(.cancelled)))
        #expect(!HostCourtesyRule.isRefusal(CancellationError()))
        #expect(!HostCourtesyRule.isRefusal(NSError(domain: "x", code: 1)))
        #expect(HostCourtesyRule.refusalRest == .seconds(30))
        #expect(HostCourtesyRule.refusalRest <= HostCourtesyRule.longestWait, "a refusal is waited out, not failed")
    }

    @Test("Rule: a request that ends unasked is no failure, no holdback and no sentence")
    func anUnaskedEndIsNoFailure() {
        let resting = HostCourtesy.Resting(host: "archive.org", remaining: .seconds(60))
        for error in [resting as Error, FetchHeldBack()] {
            #expect(error.endedUnasked)
            #expect(!FetchHoldback.starts(after: error), "no holdback for a question never asked")
            #expect(FreeCatalog.logReason(error) == nil, "logs as held, not as failed")
            #expect(FreeCatalog.failureReason(error, online: true) == nil)
        }
        #expect(!URLError(.timedOut).endedUnasked)
        #expect(FetchHoldback.starts(after: URLError(.timedOut)))
    }

    // MARK: - The actor, own instance

    @Test("Actor: a refused connection lets the whole host rest, for every path")
    func aRefusalRestsTheHost() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let pass = try await courtesy.enter(Self.url("archive.org"))
        await courtesy.leave(pass, status: nil, retryAfter: nil, refused: true)
        let remaining = try #require(await courtesy.restRemaining(group: "archive.org"))
        #expect(remaining > .seconds(29) && remaining <= .seconds(30))
        #expect(await courtesy.counts(group: "archive.org").refused == 1)
        #expect(await courtesy.restRemaining(group: "ia800.us.archive.org") == nil,
                "a file server is a machine of its own")
    }

    @Test("Actor: a refused connection does NOT let an own server rest, the next request goes at once")
    func aRefusalDoesNotRestAnOwnServer() async throws {
        let courtesy = HostCourtesy(ownHosts: { ["abs.home.example", "sync.home.example"] })
        let clock = ContinuousClock()
        for host in ["abs.home.example", "sync.home.example"] {
            let first = try await courtesy.enter(Self.url(host))
            await courtesy.leave(first, status: nil, retryAfter: nil, refused: true)
            #expect(await courtesy.restRemaining(group: host) == nil, "\(host) rests after a refusal")
            let started = clock.now
            let second = try await courtesy.enter(Self.url(host))
            #expect(started.duration(to: clock.now) < .milliseconds(200), "\(host) waited after a refusal")
            await courtesy.leave(second, status: 200, retryAfter: nil)
            #expect(await courtesy.counts(group: host).asked == 2, "both requests went out")
        }
        // A 429 from an own server still rests it.
        let pass = try await courtesy.enter(Self.url("abs.home.example"))
        await courtesy.leave(pass, status: 429, retryAfter: "5")
        #expect(await courtesy.restRemaining(group: "abs.home.example") != nil)
    }

    @Test("Actor: after a refused connection a deliberate question goes at once, an unmarked one waits, a 429 holds both")
    func aDeliberateQuestionPassesTheRefusalRest() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let clock = ContinuousClock()
        let first = try await courtesy.enter(Self.url("new.example"))
        await courtesy.leave(first, status: nil, retryAfter: nil, refused: true)
        #expect(await courtesy.restRemaining(group: "new.example") != nil, "the refusal rests the host")
        let started = clock.now
        let pressed = try await LookupOccasion.deliberate { try await courtesy.enter(Self.url("new.example")) }
        #expect(started.duration(to: clock.now) < .milliseconds(200), "the press waited out the rest")
        // The server is still down: the press is refused too, the rest stands.
        await courtesy.leave(pressed, status: nil, retryAfter: nil, refused: true)
        #expect(await courtesy.counts(group: "new.example").asked == 2, "the press did not go out")
        let passed = Passed()
        let unmarked = Task {
            let pass = try await courtesy.enter(Self.url("new.example"))
            await passed.add()
            return pass
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await passed.count == 0, "an unmarked question went out during the rest")
        unmarked.cancel()
        _ = await unmarked.result
        // A 429 holds the press like everything else.
        let asked = try await LookupOccasion.deliberate { try await courtesy.enter(Self.url("new.example")) }
        let rested = clock.now
        await courtesy.leave(asked, status: 429, retryAfter: "1")
        let afterRest = try await LookupOccasion.deliberate { try await courtesy.enter(Self.url("new.example")) }
        #expect(rested.duration(to: clock.now) >= .milliseconds(950), "the press was asked during a 429 rest")
        await courtesy.leave(afterRest, status: 200, retryAfter: nil)
    }

    @Test("Actor: an answer from a refusal rest ends it, the next unmarked question goes at once")
    func anAnswerEndsTheRefusalRest() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let clock = ContinuousClock()
        let first = try await courtesy.enter(Self.url("back.example"))
        await courtesy.leave(first, status: nil, retryAfter: nil, refused: true)
        #expect(await courtesy.restRemaining(group: "back.example") != nil, "the refusal rests the host")
        let pressed = try await LookupOccasion.deliberate { try await courtesy.enter(Self.url("back.example")) }
        await courtesy.leave(pressed, status: 200, retryAfter: nil)
        #expect(await courtesy.restRemaining(group: "back.example") == nil, "the answer left the rest standing")
        let started = clock.now
        let unmarked = try await courtesy.enter(Self.url("back.example"))
        #expect(started.duration(to: clock.now) < .milliseconds(200), "an unmarked question waited after the host answered")
        await courtesy.leave(unmarked, status: 200, retryAfter: nil)
        #expect(await courtesy.counts(group: "back.example").asked == 3)
    }

    @Test("Actor: an address just remembered counts at once as an own server, not only after a minute")
    func aJustRememberedAddressIsOwnAtOnce() async throws {
        let own = OwnHosts()
        let courtesy = HostCourtesy(ownHosts: { own.current })
        #expect(await courtesy.isOwn("mine.example") == false, "the host is own before it is remembered")
        own.set(["mine.example"])
        NotificationCenter.default.post(name: KnownServers.didChange, object: nil)
        // The copy is dropped on the actor's next turn; wait for that, briefly.
        var isOwn = false
        for _ in 0..<40 where !isOwn {
            try await Task.sleep(for: .milliseconds(25))
            isOwn = await courtesy.isOwn("mine.example")
        }
        #expect(isOwn, "the copy outlived the change of the servers")
        let pass = try await courtesy.enter(Self.url("mine.example"))
        await courtesy.leave(pass, status: nil, retryAfter: nil, refused: true)
        #expect(await courtesy.restRemaining(group: "mine.example") == nil, "a refusal rested the just-remembered server")
    }

    /// The own servers of a witness, changeable from outside.
    nonisolated final class OwnHosts: Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var hosts: Set<String> = []
        var current: Set<String> { lock.withLock { hosts } }
        func set(_ new: Set<String>) { lock.withLock { hosts = new } }
    }

    /// Counts how many `enter` have already returned.
    actor Passed {
        var count = 0
        func add() { count += 1 }
    }

    private static func url(_ host: String) -> URL { URL(string: "https://\(host)/x")! }

    @Test("Actor: never more than four at once to a third-party host, the fifth waits for a slot")
    func capOfFour() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        var passes: [HostCourtesy.Pass] = []
        for _ in 0..<4 { passes.append(try await courtesy.enter(Self.url("a.example"))) }
        let passed = Passed()
        let fifth = Task {
            let pass = try await courtesy.enter(Self.url("a.example"))
            await passed.add()
            return pass
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await passed.count == 0, "the fifth request went out beside four")
        #expect(await courtesy.counts(group: "a.example").inFlight == 4)
        await courtesy.leave(passes[0], status: 200, retryAfter: nil)
        let fifthPass = try await fifth.value
        #expect(await passed.count == 1, "a slot that frees goes to the one waiting")
        #expect(await courtesy.counts(group: "a.example").inFlight == 4)
        #expect(await courtesy.counts(group: "a.example").held == 1)
        for pass in passes.dropFirst() + [fifthPass] { await courtesy.leave(pass, status: 200, retryAfter: nil) }
        #expect(await courtesy.counts(group: "a.example").inFlight == 0)
    }

    @Test("Actor: an own server has no cap, the device itself does not go through the rule")
    func ownServerAndLoopback() async throws {
        let courtesy = HostCourtesy(ownHosts: { ["abs.home.example"] })
        for _ in 0..<10 { _ = try await courtesy.enter(Self.url("abs.home.example")) }
        #expect(await courtesy.counts(group: "abs.home.example").inFlight == 10)
        let loop = try await courtesy.enter(URL(string: "http://127.0.0.1:8811/v1")!)
        #expect(!loop.counted)
    }

    @Test("Actor: MusicBrainz and the Cover Art Archive share the one second")
    func musicBrainzSpacing() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let clock = ContinuousClock()
        let started = clock.now
        let first = try await courtesy.enter(Self.url("musicbrainz.org"))
        await courtesy.leave(first, status: 200, retryAfter: nil)
        let second = try await courtesy.enter(Self.url("coverartarchive.org"))
        await courtesy.leave(second, status: 200, retryAfter: nil)
        let spent = started.duration(to: clock.now)
        #expect(spent >= .milliseconds(950), "two starts in the group less than a second apart: \(spent)")
        #expect(await courtesy.counts(group: "musicbrainz").asked == 2)
    }

    @Test("Actor: a 429 with Retry-After holds ALL requests to the host for that long, also to an own server")
    func retryAfterHoldsTheWholeHost() async throws {
        let courtesy = HostCourtesy(ownHosts: { ["own.example"] })
        let clock = ContinuousClock()
        for host in ["far.example", "own.example"] {
            let pass = try await courtesy.enter(Self.url(host))
            let refused = clock.now
            await courtesy.leave(pass, status: host == "own.example" ? 503 : 429, retryAfter: "1")
            async let a = courtesy.enter(Self.url(host))
            async let b = courtesy.enter(Self.url(host))
            let (passA, passB) = try await (a, b)
            #expect(refused.duration(to: clock.now) >= .milliseconds(950), "\(host) was asked during its rest")
            await courtesy.leave(passA, status: 200, retryAfter: nil)
            await courtesy.leave(passB, status: 200, retryAfter: nil)
            #expect(await courtesy.counts(group: host).refused == 1)
        }
    }

    @Test("Actor: a long rest sends nothing, the request ends unasked")
    func aLongRestSendsNothing() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let pass = try await courtesy.enter(Self.url("busy.example"))
        await courtesy.leave(pass, status: 429, retryAfter: "120")
        await #expect(throws: HostCourtesy.Resting.self) {
            _ = try await courtesy.enter(Self.url("busy.example"))
        }
        #expect(await courtesy.counts(group: "busy.example").asked == 1, "the resting host was asked again")
    }

    // MARK: - The fence over the ways outward

    private static func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Fence: every request to a session goes through the courtesy gate, the exceptions are named", .needsTheSources)
    func everyWayPassesTheGate() throws {
        let retry = try Self.code("Sources/Networking/Retry.swift")
        #expect(retry.contains("try await courteously(request) {\n                    try await session.data(for: request, delegate: redirects)"),
                "fetch asks its session inside the gate, per attempt")
        #expect(retry.components(separatedBy: "session.data(").count - 1 == 1)
        let http = try Self.code("Sources/Networking/HTTP.swift")
        // Each ask carries the redirect rule of the server headers as its delegate.
        for ask in ["session(lane).data(for: prepared, delegate: RedirectGuard.following())",
                    "session(.stream).bytes(for: prepared, delegate: RedirectGuard.following())",
                    "session(lane).download(for: prepared, delegate: RedirectGuard.following())",
                    "session(lane).upload(for: prepared, fromFile: file, delegate: RedirectGuard.following())"] {
            #expect(http.contains("courteously(prepared) {") && http.contains(ask), "\(ask)")
            let site = try #require(http.range(of: ask))
            let before = http[..<site.lowerBound].suffix(80)
            #expect(before.contains("courteously(prepared)"), "\(ask) asks past the gate")
        }
        // Named exceptions: the socket lane talks to the person's own sync
        // service and holds one standing connection; the background session
        // is scheduled by the system and runs what the person asked for.
        #expect(http.components(separatedBy: "webSocketTask(with:").count - 1 == 1)
        let downloader = try Self.code("Sources/Networking/FileDownloader.swift")
        #expect(downloader.components(separatedBy: "downloadTask(with: ").count - 1 == 1)
        #expect(downloader.components(separatedBy: "downloadTask(withResumeData: ").count - 1 == 1)
    }

    @Test("Fence: one ledger per host, and unasked is answered at the source, not by name", .needsTheSources)
    func oneLedgerOneQuestion() throws {
        var byName: [String] = []
        var refusalCallers: Set<String> = []
        var refusalDefinitions: Set<String> = []
        var read = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            read += 1
            let name = file.lastPathComponent
            if text.contains("is FetchHeldBack") || text.contains("as? FetchHeldBack") { byName.append(name) }
            if text.contains("func isRefusal(") { refusalDefinitions.insert(name) }
            if text.contains(".isRefusal(") { refusalCallers.insert(name) }
        }
        #expect(read > 100, "der Zaun hat die Quellen nicht gelesen: \(read)")
        #expect(byName.isEmpty, "a place asks for an unasked end by name: \(byName)")
        #expect(refusalDefinitions == ["HostCourtesyRule.swift"], "\(refusalDefinitions)")
        #expect(refusalCallers == ["Retry.swift"], "a refusal is booked in the one ledger only: \(refusalCallers)")
    }

    @Test("Fence: nobody but the gate keeps an own spacing toward a third-party service", .needsTheSources)
    func noOwnPace() throws {
        for path in ["Sources/Networking/CoverArtArchive.swift", "Sources/Networking/RadioArtworkService.swift",
                     "Sources/Networking/ArtistPortraitService.swift", "Sources/Networking/RadioLogoService.swift"] {
            let text = try Self.code(path)
            #expect(!text.contains("Task.sleep") && !text.contains("lastRequest"), "\(path) keeps its own pace")
        }
    }
}
#endif
