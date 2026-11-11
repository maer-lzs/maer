// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
@testable import Maer

/// How far planned tracks may join a playing queue.
struct QueueAppendTests {
    @Test("Anhaengen: bis zur letzten Spur, bis vor einen gehaltenen Ladefehler, gar nicht nach einem Halt")
    func theEnd() {
        #expect(QueueAppend.end(trackCount: 5, heldAt: nil, failureNoted: false) == 5)
        #expect(QueueAppend.end(trackCount: 5, heldAt: 3, failureNoted: false) == 3)
        #expect(QueueAppend.end(trackCount: 5, heldAt: 3, failureNoted: true) == 0)
        #expect(QueueAppend.end(trackCount: 5, heldAt: nil, failureNoted: true) == 0)
        #expect(QueueAppend.end(trackCount: 5, heldAt: 9, failureNoted: false) == 5)
        #expect(QueueAppend.end(trackCount: 5, heldAt: -1, failureNoted: false) == 0)
    }
}

/// The queue of a title whose tracks need plans (a source with a sign-in):
/// nothing joins it behind a held load failure, every rebuild after a load
/// failure asks the plan of its track anew, and a queue that ran out
/// waiting for a plan goes on or stops with a hint.
@Suite(.serialized)
@MainActor
struct PlannedQueueTests {
    typealias Host = HeaderRedirectMeasureTests.RecordingHost

    /// The asks of a host for the end of a track's redirects, by path.
    static func asks(_ host: Host, _ path: String) -> Int {
        host.recorded.filter { $0.contains(path) && $0.contains("range: bytes=0-0") }.count
    }

    /// The requests of a host for a track's stream, by path.
    static func streamed(_ host: Host, _ path: String) -> Int {
        host.recorded.filter { $0.contains(path) && !$0.contains("range: bytes=0-0") }.count
    }

    /// A title of one-second tracks at these addresses.
    func title(_ addresses: [String]) -> LibraryItemDetail {
        LibraryItemDetail(
            id: "planned-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: Double(addresses.count), chapters: nil,
                                    tracks: addresses.enumerated().map { index, address in
                                        ABSAudioTrack(index: index, startOffset: Double(index), duration: 1,
                                                      contentUrl: address, metadata: nil)
                                    }),
            userMediaProgress: nil)
    }

    func host(delay: Double = 0) async throws -> Host {
        let host = try Host(body: try HeaderRedirectMeasureTests.tone(), contentType: "audio/x-caf", delay: delay)
        try await host.start()
        return host
    }

    func model(elsewhere: [String: String]? = [:]) -> PlayerViewModel {
        PlayerViewModel(provider: ServerHeadersWayTests.HostBoundProvider(host: "127.0.0.1", elsewhere: elsewhere),
                        localTracks: { _ in [:] }, isOnline: { true })
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Tracks 0 to 2 at a quick host, 3 to 5 at one whose answers take a second.
    func sixTracks() async throws -> (quick: Host, slow: Host, title: LibraryItemDetail) {
        let quick = try await host()
        let slow = try await host(delay: 1)
        let addresses = (0..<6).map { "http://127.0.0.1:\($0 < 3 ? quick.port : slow.port)/track-\($0).caf" }
        return (quick, slow, title(addresses))
    }

    @Test("Plan zuerst: Spuren hinter einem Ladefehler, die schon in der Warteschlange standen, gehen mit ihm, und ein spaeter landender Plan haengt nichts dahinter an")
    func aPlanThatLandsBeforeTheHeldFailureLeavesNothingBehindIt() async throws {
        let (quick, slow, title) = try await sixTracks()
        defer { quick.stop(); slow.stop() }
        let model = model()
        await model.load(item: title)
        await waitFor { model._testQueuedTracks() == [0, 1, 2] }
        try #require(model._testQueuedTracks() == [0, 1, 2], "the precondition: the start queued its window")
        model._testPlanWindow(from: 2)
        await waitFor { model._testQueuedTracks() == [0, 1, 2, 3, 4] }
        try #require(model._testQueuedTracks() == [0, 1, 2, 3, 4], "the precondition: the plans of 3 and 4 landed and joined")
        model._testHoldAhead(at: 3, then: .none)
        #expect(model._testQueuedTracks() == [0, 1, 2], "the held failure left tracks behind it")
        // The plan of track 5 lands after the failure is held.
        model._testPlanWindow(from: 3)
        await waitFor { Self.asks(slow, "/track-5.") == 1 }
        try #require(Self.asks(slow, "/track-5.") == 1, "the precondition: track 5 was asked")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(model._testQueuedTracks() == [0, 1, 2], "a plan that landed later joined behind the held failure: \(model._testQueuedTracks())")
        model.stop()
    }

    @Test("Ladefehler zuerst: ein Plan, der nach dem gehaltenen Ladefehler landet, haengt nichts an, und die Wiedergabe haelt vor ihm",
          .needsAudio)
    func aPlanThatLandsAfterTheHeldFailureLeavesNothingBehindIt() async throws {
        let (quick, slow, title) = try await sixTracks()
        defer { quick.stop(); slow.stop() }
        let model = model()
        await model.load(item: title)
        await waitFor { model._testQueuedTracks() == [0, 1, 2] }
        try #require(model._testQueuedTracks() == [0, 1, 2], "the precondition: the start queued its window")
        model._testHoldAhead(at: 3, then: .none)
        // The plans of 3 and 4 are asked after the failure is held.
        model._testPlanWindow(from: 2)
        await waitFor { Self.asks(slow, "/track-4.") == 1 }
        try #require(Self.asks(slow, "/track-3.") == 1, "the precondition: track 3 was asked")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(model._testQueuedTracks() == [0, 1, 2], "a plan that landed after the held failure joined behind it: \(model._testQueuedTracks())")
        model.player?.volume = 0
        model.play()
        await waitFor { model.sourceHint?.kind == .loadFailed }
        #expect(model.sourceHint?.kind == .loadFailed, "playback did not stop at the held failure")
        #expect(model.currentTime == 3, "playback stopped at \(model.currentTime) s, not at the start of the held track")
        #expect(!model.isPlaying)
        let behind = (3..<6).map { Self.streamed(slow, "/track-\($0).") }
        #expect(behind == [0, 0, 0], "a track at or behind the held failure was streamed: \(behind)")
        model.stop()
    }

    @Test("ein Ladefehler der laufenden Spur baut neu und fragt dabei den Plan der Spur neu")
    func aFailureOfThePlayingTrackAsksItsPlanAnew() async throws {
        let (quick, slow, title) = try await sixTracks()
        defer { quick.stop(); slow.stop() }
        let model = model()
        await model.load(item: title)
        await waitFor { model._testQueuedTracks() == [0, 1, 2] }
        try #require(Self.asks(quick, "/track-0.") == 1, "the precondition: the start asked track 0 once")
        model._testFailPlaying()
        await waitFor { Self.asks(quick, "/track-0.") == 2 }
        #expect(Self.asks(quick, "/track-0.") == 2, "the rebuild after the failure built from the plan of before")
        await waitFor { model._testQueuedTracks().first == 0 }
        #expect(model._testQueuedTracks().first == 0, "the rebuild built no queue at the failed track")
        model.stop()
    }

    @Test("ein gehaltener Ladefehler, der vom Server weiterlaeuft, baut neu und fragt dabei den Plan der Spur neu")
    func aHeldFailureThatPlaysOnFromTheServerAsksItsPlanAnew() async throws {
        let (quick, slow, title) = try await sixTracks()
        defer { quick.stop(); slow.stop() }
        let model = model()
        await model.load(item: title)
        await waitFor { model._testQueuedTracks() == [0, 1, 2] }
        try #require(Self.asks(quick, "/track-1.") == 1, "the precondition: the start asked track 1 once")
        model._testHoldAhead(at: 1, then: .stream)
        model._testStopAtHeld()
        await waitFor { Self.asks(quick, "/track-1.") == 2 }
        #expect(Self.asks(quick, "/track-1.") == 2, "the rebuild at the held track built from the plan of before")
        await waitFor { model._testQueuedTracks().first == 1 }
        #expect(model._testQueuedTracks().first == 1, "the rebuild built no queue at the held track")
        model.stop()
    }

    @Test("eine Warteschlange, deren naechste Spur jetzt nicht gefragt werden kann, haelt mit Hinweis statt bei spielt zu stehen, und ein spaeterer Druck auf Wiedergabe fragt neu",
          .needsAudio)
    func aDryQueueWhoseNextTrackCannotBeAskedStopsWithAHint() async throws {
        let quick = try await host()
        let origin = try await host()
        let other = try await host()
        defer { quick.stop(); origin.stop(); other.stop() }
        // Track 1 ends at another host, whose sign-in cannot be read now.
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/end-1.caf")))
        let model = model(elsewhere: nil)
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(origin.port)/start-1.caf"]))
        try #require(model.player != nil, "the precondition: the load built a player")
        await waitFor { Self.asks(origin, "/start-1.") == 1 }
        try #require(Self.asks(origin, "/start-1.") == 1, "the precondition: track 1 was asked")
        try await Task.sleep(for: .milliseconds(300))
        model.player?.volume = 0
        model.play()
        await waitFor { !model.isPlaying }
        #expect(!model.isPlaying, "the queue ran out and playback stands at playing")
        #expect(model.sourceHint?.kind == .cannotPlay, "the stop said nothing: \(String(describing: model.sourceHint))")
        #expect(model.currentTime == 1, "playback stopped at \(model.currentTime) s, not at the start of the track it waited for")
        #expect(!model.isFinished, "the title was marked finished at a track it could not ask")
        // A later play asks the plan anew, and stops again while it cannot be had.
        model.sourceHint = nil
        model.play()
        await waitFor { Self.asks(origin, "/start-1.") == 2 }
        #expect(Self.asks(origin, "/start-1.") == 2, "the later play did not ask the plan anew")
        await waitFor { !model.isPlaying && model.sourceHint != nil }
        #expect(!model.isPlaying, "the later play stands at playing without a queue")
        #expect(model.sourceHint?.kind == .cannotPlay)
        model.stop()
    }

    @Test("eine Warteschlange, die auf den Plan der naechsten Spur wartet, laeuft weiter, wenn er kommt",
          .needsAudio)
    func aDryQueueGoesOnWhenThePlanComes() async throws {
        let quick = try await host()
        let slow = try await host(delay: 2)
        defer { quick.stop(); slow.stop() }
        let model = model()
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(slow.port)/track-1.caf"]))
        try #require(model._testQueuedTracks() == [0], "the precondition: the queue holds only the first track")
        model.player?.volume = 0
        model.play()
        await waitFor { model._testQueuedTracks() == [1] }
        #expect(model._testQueuedTracks() == [1], "the next track did not join: \(model._testQueuedTracks())")
        #expect(model.isPlaying, "playback stopped although the plan came")
        #expect(model.sourceHint == nil, "a hint came although the plan came: \(String(describing: model.sourceHint))")
        model.stop()
    }

    @Test("eine Spur, die die leergelaufene Warteschlange im selben Durchlauf aufnimmt, laeuft zuerst; der Halt vor der Spur dahinter kommt an ihrem Ende",
          .needsAudio)
    func aTrackThatJoinsBeforeAWaitingOnePlaysFirst() async throws {
        let quick = try await host()
        let slow = try await host(delay: 2)
        let origin = try await host()
        let other = try await host()
        defer { quick.stop(); slow.stop(); origin.stop(); other.stop() }
        // Track 2 ends at another host, whose sign-in cannot be read now.
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/end-2.caf")))
        let model = model(elsewhere: nil)
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(slow.port)/track-1.caf",
                                      "http://127.0.0.1:\(origin.port)/start-2.caf"]))
        await waitFor { Self.asks(origin, "/start-2.") == 1 }
        try #require(Self.asks(origin, "/start-2.") == 1, "the precondition: track 2 was asked")
        try #require(model._testQueuedTracks() == [0], "the precondition: track 1 waits for its plan")
        model.player?.volume = 0
        model.play()
        await waitFor { model._testQueuedTracks().contains(1) }
        #expect(model._testQueuedTracks().contains(1), "track 1 did not join: \(model._testQueuedTracks())")
        #expect(model.isPlaying, "playback stopped as track 1 joined")
        #expect(model.currentTime < 2, "the position jumped over track 1 to \(model.currentTime) s")
        await waitFor({ !model.isPlaying }, seconds: 15)
        #expect(!model.isPlaying, "playback did not stop before track 2")
        #expect(model.sourceHint?.kind == .cannotPlay)
        #expect(model.currentTime == 2, "playback stopped at \(model.currentTime) s, not at the start of track 2")
        #expect(Self.streamed(slow, "/track-1.") > 0, "track 1 was never streamed")
        model.stop()
    }

    /// Tracks 1 to 7 at a host that holds every answer ten seconds, 0 and 8
    /// to 10 at a quick one; after the start's window and the one from
    /// track 3, four asks ahead hold every turn.
    func heldTurns() async throws -> (hold: Host, quick: Host, model: PlayerViewModel) {
        let hold = try await host(delay: 10)
        let quick = try await host()
        let model = model()
        await model.load(item: title((0..<11).map { "http://127.0.0.1:\($0 == 0 || $0 >= 8 ? quick.port : hold.port)/track-\($0).caf" }))
        try #require(model.player != nil, "the precondition: the load built a player")
        model._testPlanWindow(from: 3)
        return (hold, quick, model)
    }

    @Test("die Spur eines Sprungs wird sofort gefragt, nicht hinter den Vorab-Fragen, die alle Plaetze halten")
    func aJumpIsNotAskedBehindTheAsksAhead() async throws {
        let (hold, quick, model) = try await heldTurns()
        defer { hold.stop(); quick.stop() }
        // Tracks 7 to 9 wait for a turn behind the held asks.
        model._testPlanWindow(from: 7)
        try await Task.sleep(for: .milliseconds(200))
        try #require(Self.asks(quick, "/track-8.") == 0, "the precondition: track 8 waits for its turn")
        // A track not asked yet.
        var began = Date()
        await model.seek(to: 10.5, userInitiated: false)
        var asked = Date().timeIntervalSince(began)
        #expect(asked < 1.2, "the jump's new ask waited for a turn: \(asked) s")
        #expect(Self.asks(quick, "/track-10.") == 1)
        #expect(PlannedQueueTests.playing(model) == "track-10.caf")
        // A track whose ask waits for its turn.
        began = Date()
        await model.seek(to: 8.5, userInitiated: false)
        asked = Date().timeIntervalSince(began)
        #expect(asked < 1.2, "the jump's track was asked behind the asks ahead: \(asked) s")
        #expect(Self.asks(quick, "/track-8.") == 1)
        #expect(PlannedQueueTests.playing(model) == "track-8.caf")
        model.stop()
    }

    /// A source whose sign-in is read for 127.0.0.1 and cannot be read
    /// elsewhere, nor for the paths locked meanwhile.
    final class LockingProvider: AudioProvider {
        var locked: Set<String> = []
        var providerId: String { "locking" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func streamAuthHeaders(forItemId itemId: String, to url: URL) -> [String: String]? {
            url.host == "127.0.0.1" && !locked.contains(url.path) ? ["Authorization": "Basic cGxhbjpwbGFu"] : nil
        }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "locking", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { URL(string: contentPath) }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("haelt die leergelaufene Warteschlange vor einer Spur, die nicht gefragt werden kann, und die Spur davor kann nicht gebaut werden, steht der Stand auf der Spur davor",
          .needsAudio)
    func aDryQueueStopsAtTheTrackItWaitedFor() async throws {
        let quick = try await host()
        let slow = try await host(delay: 2)
        let origin = try await host()
        let other = try await host()
        defer { quick.stop(); slow.stop(); origin.stop(); other.stop() }
        // Track 2 ends at another host, whose sign-in cannot be read now.
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/end-2.caf")))
        let provider = LockingProvider()
        let model = PlayerViewModel(provider: provider, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(slow.port)/track-1.caf",
                                      "http://127.0.0.1:\(origin.port)/start-2.caf"]))
        await waitFor { Self.asks(origin, "/start-2.") == 1 }
        try #require(Self.asks(origin, "/start-2.") == 1, "the precondition: track 2 was asked")
        try #require(model._testQueuedTracks() == [0], "the precondition: track 1 waits for its plan")
        // The sign-in of track 1 cannot be read any more: it cannot be built.
        provider.locked.insert("/track-1.caf")
        model.player?.volume = 0
        model.play()
        await waitFor({ !model.isPlaying }, seconds: 15)
        #expect(!model.isPlaying, "the queue ran out and playback stands at playing")
        #expect(model.sourceHint?.kind == .cannotPlay)
        #expect(model.currentTime == 1, "playback stopped at \(model.currentTime) s, behind the track it waited for")
        model.stop()
    }

    @Test("ein Sprung an einen Wirt, der die Frage nach dem Ende annimmt und nie beantwortet, zeigt das Warten und baut nach der Grenze der Frage")
    func aJumpToASilentHostShowsTheWaitAndEndsAtTheLimit() async throws {
        let quick = try await host()
        let silent = try await host(delay: 30)
        defer { quick.stop(); silent.stop() }
        let model = model()
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(silent.port)/track-1.caf"]))
        try #require(model.player != nil, "the precondition: the load built a player")
        let began = Date()
        let jump = Task { await model.seek(to: 1.5, userInitiated: false) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.waitsOnTheStream, "the jump waits for its plan and shows nothing")
        await jump.value
        let waited = Date().timeIntervalSince(began)
        // The limit of the ask is 10 s; the host answers after 30.
        #expect(waited < 14, "the jump waited \(waited) s, past the limit of the ask")
        #expect(PlannedQueueTests.playing(model) == "track-1.caf", "the jump built nothing after the ask ended")
        #expect(!model.waitsOnTheStream, "the wait still shows after the jump built")
        model.stop()
    }

    @Test("ist die Anmeldung der naechsten Spur gerade unlesbar, haelt die leergelaufene Warteschlange mit Hinweis an ihrem Anfang",
          .needsAudio)
    func aDryQueueWhoseNextSignInCannotBeReadStops() async throws {
        let quick = try await host()
        let slow = try await host(delay: 2)
        defer { quick.stop(); slow.stop() }
        let provider = LockingProvider()
        let model = PlayerViewModel(provider: provider, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: title(["http://127.0.0.1:\(quick.port)/track-0.caf",
                                      "http://127.0.0.1:\(slow.port)/track-1.caf"]))
        try #require(model._testQueuedTracks() == [0], "the precondition: track 1 waits for its plan")
        // The sign-in of track 1 cannot be read any more.
        provider.locked.insert("/track-1.caf")
        model.player?.volume = 0
        model.play()
        await waitFor({ !model.isPlaying }, seconds: 15)
        #expect(!model.isPlaying, "the queue ran out and playback stands at playing")
        #expect(model.sourceHint?.kind == .cannotPlay, "the stop said nothing: \(String(describing: model.sourceHint))")
        #expect(model.currentTime == 1, "playback stopped at \(model.currentTime) s, not at the start of track 1")
        model.stop()
    }

    static func playing(_ model: PlayerViewModel) -> String? {
        (model.player?.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
    }
}
#endif
