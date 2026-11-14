// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
import os
@testable import Maer

/// A source's sign-in in a stream stays with the source's host, also when
/// the source redirects the stream to another host.
@Suite(.serialized)
@MainActor
struct SignInStreamTests {
    typealias Host = HeaderRedirectMeasureTests.RecordingHost

    nonisolated static let signIn = ["Authorization": "Basic cGxhbjpwbGFu"]
    nonisolated static let needle = "authorization: basic cgxhbjpwbgfu"

    /// The source's answer per address as its rule gives it: the sign-in for
    /// its own host, never from https down to http, none anywhere else.
    static func answer(own: URL) -> @Sendable (URL) async -> [String: String]? {
        { SignInReach.mayCarry(own: own, target: $0) ? signIn : [:] }
    }

    @Test("the rule: the end on the own host gets the sign-in, a foreign host and https to http do not, an unknown end is not asked")
    func theRule() async throws {
        let own = try #require(URL(string: "https://feed.example.org/feed.xml"))
        let start = try #require(URL(string: "https://feed.example.org/audio/1.mp3"))
        let moved = try #require(URL(string: "https://feed.example.org/files/1.mp3?v=2"))
        let foreign = try #require(URL(string: "https://cdn.example.net/1.mp3?sig=abc&exp=1"))
        let downgraded = try #require(URL(string: "http://feed.example.org/files/1.mp3"))
        let signIn = Self.answer(own: own)

        let stays = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: signIn) { _ in moved }
        #expect(stays == .resolved(moved, headers: Self.signIn), "an end at the source's host lost the sign-in")
        let leaves = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: signIn) { _ in foreign }
        #expect(leaves == .resolved(foreign, headers: [:]), "an end at another host got the sign-in")
        let down = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: signIn) { _ in downgraded }
        #expect(down == .resolved(downgraded, headers: [:]), "an end over http got a sign-in given over https")
        let unknown = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: signIn) { _ in nil }
        #expect(unknown == .unanswered, "an end that cannot be asked went to the address with the sign-in")
        let unreadable = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: { _ in nil }) { _ in foreign }
        #expect(unreadable == .waiting, "a sign-in that cannot be read for the end is asked without it")
        // The question for the end carries the sign-in to the source's address.
        actor Seen { var request: URLRequest?; func note(_ r: URLRequest) { request = r } }
        let seen = Seen()
        _ = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: signIn) { request in
            await seen.note(request)
            return moved
        }
        let asked = try #require(await seen.request)
        #expect(asked.url == start)
        #expect(asked.value(forHTTPHeaderField: "Authorization") == Self.signIn["Authorization"])
    }

    /// Two hosts on the loopback: the source's (127.0.0.1) redirects every
    /// path under `/start` to the other (localhost), which answers in ranges
    /// as a file host does.
    func hosts() async throws -> (origin: Host, other: Host) {
        let body = try Data(contentsOf: try TickWorkTests().tone(seconds: 60))
        let origin = try Host(body: body, contentType: "audio/x-caf")
        let other = try Host(body: body, contentType: "audio/x-caf")
        try await origin.start()
        try await other.start()
        return (origin, other)
    }

    func book(_ address: String, seconds: Double = 60) -> LibraryItemDetail {
        LibraryItemDetail(
            id: "signin-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: seconds, chapters: nil, tracks: [
                ABSAudioTrack(index: 0, startOffset: 0, duration: seconds, contentUrl: address, metadata: nil),
            ]),
            userMediaProgress: nil)
    }

    @Test("the target of a redirect to another host sees the sign-in in no request of the stream, also after a jump",
          .needsAudio)
    func theTargetOfARedirectNeverSeesTheSignIn() async throws {
        let (origin, other) = try await hosts()
        defer { origin.stop(); other.stop() }
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/final.caf?sig=abc&exp=1794300000")))
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await model.load(item: book("http://127.0.0.1:\(origin.port)/start-book.caf"))
            try #require(model.player != nil, "the precondition: the load built a player")
            model.player?.volume = 0
            model.play()
            try await Task.sleep(for: .seconds(2))
            await model.seek(to: 45, userInitiated: false)
            try await Task.sleep(for: .seconds(2))
            model.stop()
        }
        try await Task.sleep(for: .milliseconds(400))
        let atOrigin = origin.recorded.filter { $0.contains("/start-book.caf") }
        let atTarget = other.recorded.filter { $0.contains("/final.caf") }
        #expect(atOrigin.contains { $0.contains(Self.needle) } == true, "the instrument: the source's own host saw the sign-in")
        try #require(atTarget.count >= 2, "the target was asked \(atTarget.count) times, the stream did not reach it")
        let carried = atTarget.filter { $0.contains(Self.needle) }.count
        #expect(carried == 0, "the target of the redirect saw the sign-in in \(carried) of \(atTarget.count) requests")
        #expect(atTarget.contains { $0.contains("authorization:") } == false)
    }

    @Test("a stream whose source does not redirect keeps the sign-in on the own host", .needsAudio)
    func aStreamThatStaysKeepsItsSignIn() async throws {
        let (origin, other) = try await hosts()
        defer { origin.stop(); other.stop() }
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await model.load(item: book("http://127.0.0.1:\(origin.port)/direct.caf"))
            try #require(model.player != nil, "the precondition: the load built a player")
            model.player?.volume = 0
            model.play()
            try await Task.sleep(for: .seconds(2))
            model.stop()
        }
        let asked = origin.recorded.filter { $0.contains("/direct.caf") }
        let streamed = asked.filter { !$0.contains("range: bytes=0-0") }
        try #require(!streamed.isEmpty, "the stream did not ask its file")
        #expect(streamed.allSatisfy { $0.contains(Self.needle) } == true, "a request of the stream to the source's own host went without the sign-in")
        #expect(asked.filter { $0.contains("range: bytes=0-0") }.count == 1, "the end was asked once before the stream")
        #expect(other.recorded.isEmpty)
    }

    @Test("named limit: if the own host later redirects its end address itself, the stream carries the sign-in along (measured)")
    func theNamedLimit() async throws {
        let (origin, other) = try await hosts()
        defer { origin.stop(); other.stop() }
        let own = try #require(URL(string: "http://127.0.0.1:\(origin.port)"))
        let start = try #require(URL(string: "http://127.0.0.1:\(origin.port)/late-file.caf"))
        // Asked while the host does not redirect this path: the end is the path itself.
        origin.redirecting.withLock { $0 = "/never" }
        let plan = await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: Self.answer(own: own))
        }
        try #require(plan == .resolved(start, headers: Self.signIn), "the precondition: the end is the source's own address")
        // The host redirects the same path from now on.
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/late-final.caf")))
        origin.redirecting.withLock { $0 = "/late" }
        let asset = AVURLAsset(url: start, options: ["AVURLAssetHTTPHeaderFieldsKey": Self.signIn])
        // bearable, because the measured fact is the head the host recorded, not the asset
        _ = try? await asset.load(.duration)
        try await Task.sleep(for: .milliseconds(400))
        let atTarget = other.recorded.filter { $0.contains("/late-final.caf") }
        let carried = atTarget.filter { $0.contains(Self.needle) }.count
        print("SIGNINLIMIT asked=\(atTarget.count) carried=\(carried)")
        #expect(!atTarget.isEmpty, "the later redirect was not followed, the limit was not measured")
    }

    @Test("if the question for the end fails, the stream does not go to the known address with the sign-in: playback stops with a sentence, and the next play asks again", .needsTheSources)
    func aFailedAskHolds() async throws {
        let own = try #require(URL(string: "https://feed.example.org/feed.xml"))
        let start = try #require(URL(string: "https://feed.example.org/audio/1.mp3"))
        let plan = await SignInStream.plan(for: start, sourceHeaders: Self.signIn, signIn: Self.answer(own: own)) { _ in nil }
        #expect(plan == .unanswered, "a failed ask planned the stream at its address with the sign-in")
        let model = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel.swift")
        #expect(model.contains("case .unanswered: Logger.player.notice(\"PLAY not requested, the end of the stream could not be asked: track=\\(index)\") return nil"),
                "a stream whose end was not asked is built")
        #expect(model.contains("if plan == .waiting || plan == .unanswered {"), "a queue skips a track whose end was not asked")
        #expect(model.contains("stopWaitingForPlan(at: waitedFor, unanswered: plan == .unanswered)"))
        #expect(model.contains("if unanswered { cannotPlay(String(localized: \"Could not load. Tap play to try again.\"))"),
                "the hold says no sentence of its own")
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("after a load error the track is planned again: an end address that no longer answers does not hold the title",
          .needsAudio)
    func aLapsedEndIsPlannedAnew() async throws {
        let body = try Data(contentsOf: try TickWorkTests().tone(seconds: 60))
        let origin = try Host(body: body, contentType: "audio/x-caf")
        let lapsing = try Host(body: body, contentType: "audio/x-caf", delay: 0.5)
        let fresh = try Host(body: body, contentType: "audio/x-caf")
        try await origin.start()
        try await lapsing.start()
        try await fresh.start()
        defer { origin.stop(); lapsing.stop(); fresh.stop() }
        origin.redirect(to: try #require(URL(string: "http://localhost:\(lapsing.port)/final-old.caf?sig=old")))
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await model.load(item: book("http://127.0.0.1:\(origin.port)/start-lapse.caf"))
            try #require(model.player != nil, "the precondition: the load built a player")
            model.player?.volume = 0
            // The end the plan names stops answering, and the source now
            // redirects to another one.
            lapsing.stop()
            origin.redirect(to: try #require(URL(string: "http://localhost:\(fresh.port)/final-new.caf?sig=new")))
            model.play()
            await waitFor { model.sourceHint?.kind == .loadFailed }
            try #require(model.sourceHint?.kind == .loadFailed, "the precondition: the stream at the lapsed end failed to load")
            #expect(fresh.recorded.isEmpty, "the precondition: nothing asked the new end yet")
            model.play()
            await waitFor { fresh.recorded.contains { $0.contains("/final-new.caf") && !$0.contains("range: bytes=0-0") } }
            model.stop()
        }
        let atFresh = fresh.recorded.filter { $0.contains("/final-new.caf") }
        #expect(atFresh.contains { !$0.contains("range: bytes=0-0") } == true,
                "the play after the failure built its stream from the lapsed plan again")
        #expect(atFresh.contains { $0.contains("authorization:") } == false, "the new end saw the sign-in")
    }

    @Test("a jump to a track whose held plan points to an expired end falls into the load error, and the next press on play asks for the end again",
          .needsAudio)
    func aJumpToALapsedEndIsPlannedAnew() async throws {
        let body = try Data(contentsOf: try TickWorkTests().tone(seconds: 60))
        let quick = try Host(body: body, contentType: "audio/x-caf")
        let origin = try Host(body: body, contentType: "audio/x-caf")
        let lapsing = try Host(body: body, contentType: "audio/x-caf")
        let fresh = try Host(body: body, contentType: "audio/x-caf")
        for host in [quick, origin, lapsing, fresh] { try await host.start() }
        defer { quick.stop(); origin.stop(); lapsing.stop(); fresh.stop() }
        origin.redirect(to: try #require(URL(string: "http://localhost:\(lapsing.port)/jump-old.caf?sig=old")))
        let title = LibraryItemDetail(
            id: "signin-jump-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 120, chapters: nil, tracks: [
                ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "http://127.0.0.1:\(quick.port)/track-0.caf", metadata: nil),
                ABSAudioTrack(index: 1, startOffset: 60, duration: 60, contentUrl: "http://127.0.0.1:\(origin.port)/start-jump.caf", metadata: nil),
            ]),
            userMediaProgress: nil)
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: title)
        try #require(model.player != nil, "the precondition: the load built a player")
        await waitFor { lapsing.recorded.contains { $0.contains("/jump-old.caf") } }
        try #require(lapsing.recorded.contains { $0.contains("/jump-old.caf") }, "the precondition: the window planned track 1")
        // A long pause: the end the held plan names stops answering, and
        // the source now redirects to another one.
        lapsing.stop()
        origin.redirect(to: try #require(URL(string: "http://localhost:\(fresh.port)/jump-new.caf?sig=new")))
        await model.seek(to: 61, userInitiated: false)
        await waitFor { model.sourceHint?.kind == .loadFailed }
        try #require(model.sourceHint?.kind == .loadFailed, "the jump to the lapsed end did not fail to load")
        model.player?.volume = 0
        model.play()
        await waitFor { fresh.recorded.contains { $0.contains("/jump-new.caf") && !$0.contains("range: bytes=0-0") } }
        model.stop()
        #expect(fresh.recorded.contains { $0.contains("/jump-new.caf") && !$0.contains("range: bytes=0-0") },
                "the play after the failed jump built its stream from the lapsed plan again")
    }

    @Test("a host that holds the question for the end for two seconds holds the start, and the stream carries no sign-in at the foreign end",
          .needsAudio)
    func aHostThatHoldsTheAskHoldsTheStart() async throws {
        let body = try HeaderRedirectMeasureTests.tone()
        let holding = try Host(body: body, contentType: "audio/x-caf", delay: 2)
        let other = try Host(body: body, contentType: "audio/x-caf")
        try await holding.start()
        try await other.start()
        defer { holding.stop(); other.stop() }
        holding.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/held-end.caf")))
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        let began = Date()
        await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await model.load(item: book("http://127.0.0.1:\(holding.port)/start-held.caf", seconds: 1))
        }
        let waited = Date().timeIntervalSince(began)
        #expect(waited >= 2, "the start did not wait for the ask: \(waited) s")
        let built = try #require(model.player?.currentItem?.asset as? AVURLAsset, "the load built no stream")
        #expect(built.url.lastPathComponent == "held-end.caf", "the stream was built at an address whose end was not asked")
        model.player?.volume = 0
        model.play()
        await waitFor { other.recorded.contains { $0.contains("/held-end.caf") && !$0.contains("range: bytes=0-0") } }
        model.stop()
        let streamed = other.recorded.filter { $0.contains("/held-end.caf") && !$0.contains("range: bytes=0-0") }
        try #require(!streamed.isEmpty, "the precondition: the stream reached the end")
        #expect(other.recorded.contains { $0.contains("authorization:") } == false, "the foreign end saw the sign-in")
    }

    @Test("a load that waits for the plan of its first track reports no error after a stop")
    func aLoadThatWaitedLeavesAStoppedModelSilent() async throws {
        let body = try HeaderRedirectMeasureTests.tone()
        let slow = try Host(body: body, contentType: "audio/x-caf", delay: 2)
        try await slow.start()
        defer { slow.stop() }
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            let load = Task { await model.load(item: book("http://127.0.0.1:\(slow.port)/slow.caf", seconds: 1)) }
            try await Task.sleep(for: .milliseconds(400))
            try #require(model.player == nil, "the precondition: the load still waits for its plan")
            model.stop()
            await load.value
        }
        #expect(model.isStopped)
        #expect(model.player == nil, "the load built a player on the stopped model")
        #expect(model.sourceHint == nil, "the load spoke for a title that was left: \(String(describing: model.sourceHint))")
    }

    @Test("stop() ends the planner's questions in advance")
    func stopEndsTheAsksAhead() async throws {
        let body = try HeaderRedirectMeasureTests.tone()
        let quick = try Host(body: body, contentType: "audio/x-caf")
        let slow = try Host(body: body, contentType: "audio/x-caf", delay: 1)
        try await quick.start()
        try await slow.start()
        defer { quick.stop(); slow.stop() }
        let tracks = (0..<13).map { index in
            ABSAudioTrack(index: index, startOffset: Double(index), duration: 1,
                          contentUrl: "http://127.0.0.1:\(index == 0 ? quick.port : slow.port)/track-\(index).caf", metadata: nil)
        }
        let title = LibraryItemDetail(
            id: "ahead-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 13, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
        let model = PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        func asksAhead() -> Int { slow.recorded.filter { $0.contains("range: bytes=0-0") }.count }
        try await ServerHeaders.$witness.withValue(ServerHeadersWayTests.MemoryKeys().keys()) {
            await model.load(item: title)
            try #require(model.player != nil, "the precondition: the load built a player")
            try await Task.sleep(for: .milliseconds(300))
            model.stop()
            try await Task.sleep(for: .seconds(5))
        }
        let asked = asksAhead()
        #expect(asked >= 1, "the precondition: the planner had begun to ask ahead")
        #expect(asked <= 4, "the planner asked \(asked) of twelve tracks ahead after the title was left")
    }
}
#endif
