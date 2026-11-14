// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
import Network
import os
@testable import Maer

/// A stream that stops delivering mid-play: the player waits with
/// `isPlaying` true and never fails, so only the wait can say it. After the
/// rule's time the channel shows `waitingForNetwork`, past the time of a
/// short notice; the stream running again, a pause or another title takes
/// it away; playback is never stopped for a wait.
@MainActor
struct StallHintTests {
    /// A short notice expires after 0.2 s here, so a hint still standing
    /// later stands because it holds, not because its time is long.
    private func channel(stallHint: Double) -> (PlaybackNotices, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString)")
        return (PlaybackNotices(expirySeconds: 0.2, stallHintSeconds: stallHint, ablage: Ablage(directory: folder)), folder)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test("the hint comes after 5 s of waiting")
    func theHintAfterFiveSeconds() {
        #expect(StallRule.hintAfterSeconds == 5)
        #expect(!StallRule.hints(waitedSeconds: 4.9))
        #expect(StallRule.hints(waitedSeconds: 5))
        #expect(StallRule.hints(waitedSeconds: 600))
    }

    /// No halt timer and no deadline: the wait reaches the channel, the
    /// channel shows the hint, nothing on that way stops playback.
    @Test("a wait never stops playback: no deadline, no halt on the way of the hint", .needsTheSources)
    func aWaitNeverStopsPlayback() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let rule = try code("Sources/Models/PlaybackNotice.swift")
        let start = try #require(rule.range(of: "nonisolated enum StallRule {"), "the precondition: the rule was read")
        let ruleBody = String(rule[start.upperBound...]).components(separatedBy: "\n}\n").first ?? ""
        #expect(ruleBody.contains("hintAfterSeconds"), "the precondition: the body of the rule was read")
        #expect(!ruleBody.lowercased().contains("halt"), "the rule knows a stop again")
        let channel = try code("Sources/ViewModels/PlaybackNotices.swift")
        let wait = try #require(channel.range(of: "func streamWaits("), "the precondition: the channel's wait was read")
        // Up to the next function: the fence reads this one alone.
        let waitBody = String(channel[wait.upperBound...]).components(separatedBy: "func ").first ?? ""
        #expect(waitBody.contains("show(.waitingForNetwork"), "the precondition: the body of the wait was read")
        for stop in ["pause(", "stop(", "halt", "cannotPlay", "loadFailed"] {
            #expect(!waitBody.contains(stop), "the way of the hint holds playback: \(stop)")
        }
        let model = try code("Sources/ViewModels/PlayerViewModel.swift")
        let observe = try #require(model.range(of: "private func observeStalls(of newPlayer: AVQueuePlayer) {"))
        let observeBody = String(model[observe.upperBound...]).components(separatedBy: "func ").first ?? ""
        #expect(observeBody.contains("waitsOnTheStream = waits"), "the precondition: the body of the watch was read")
        for stop in ["pause(", "stop(", ".rate = 0", "cannotPlay", "handleItemLoadFailure"] {
            #expect(!observeBody.contains(stop), "the watch of the wait holds playback: \(stop)")
        }
    }

    @Test("the hint holds as long as the wait lasts, is no error, and running again removes only it")
    func theRuleOfTheWait() {
        let answer = NoticeRule.answer(.waitingForNetwork)
        #expect(answer == NoticeRule.Answer(pops: true, holdsUntilPlay: true, isError: false))
        var state = NoticeRule.next(NoticeRule.State(), .show(.waitingForNetwork))
        #expect(state.shown == .waitingForNetwork && state.held == .waitingForNetwork)
        state = NoticeRule.next(state, .streamResumed)
        #expect(state == NoticeRule.State(), "the wait stayed after the stream ran again: \(state)")
        let changed = NoticeRule.next(NoticeRule.next(NoticeRule.State(), .show(.waitingForNetwork)), .titleChanged)
        #expect(changed == NoticeRule.State(), "the wait stayed over another title: \(changed)")
        // A stopping error stands: the wait pushes it not aside, and the
        // stream running again does not take the error.
        var stopped = NoticeRule.next(NoticeRule.State(), .show(.loadFailed(.network)))
        stopped = NoticeRule.next(stopped, .show(.waitingForNetwork))
        #expect(stopped.shown == .loadFailed(.network), "the wait pushed a stopping error aside")
        stopped = NoticeRule.next(stopped, .streamResumed)
        #expect(stopped.shown == .loadFailed(.network) && stopped.held == .loadFailed(.network),
                "the stream running again took a stopping error: \(stopped)")
    }

    @Test("the channel shows the hint only after the time, a short wait says nothing, running again removes it")
    func theChannelTimesTheHint() async {
        let (notices, folder) = channel(stallHint: 0.3)
        defer { try? FileManager.default.removeItem(at: folder) }
        notices.streamWaits(true, title: "Buch")
        #expect(notices.shown == nil, "the hint came before its time")
        await wait(0.8)
        #expect(notices.shown == .waitingForNetwork, "a lasting wait said nothing: \(String(describing: notices.shown))")
        #expect(notices.log.last?.kind == .waitingForNetwork && notices.log.last?.title == "Buch")
        notices.streamWaits(false, title: "Buch")
        #expect(notices.shown == nil, "the hint stayed after the stream ran again")
        // A short wait ends before the time: nothing shows, nothing is logged.
        let logged = notices.log.count
        notices.streamWaits(true, title: "Buch")
        notices.streamWaits(false, title: "Buch")
        await wait(0.8)
        #expect(notices.shown == nil, "a wait that ended in time still said so")
        #expect(notices.log.count == logged)
    }

    @Test("the coordinator passes the model's wait to the channel as a state", .needsTheSources)
    func theCoordinatorHandsTheWaitOver() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(code.contains("viewModel?.$waitsOnTheStream.removeDuplicates().sink"), "the coordinator does not listen to the wait")
        #expect(code.contains("self?.notices.streamWaits(waits, title:"), "the wait does not reach the channel")
    }

    /// Serves a WAV with ranges: long reads get the first `sendBytes` and a
    /// hard close, every later long read a close without a byte, the way a
    /// dead link stops delivering (measured: a ready item and a wait with
    /// `WaitingToMinimizeStalls`, never `.failed`). Unchecked because the
    /// listener and its connections are only touched on the listener's own
    /// queue after start.
    nonisolated final class CuttingHost: @unchecked Sendable {
        private let listener: NWListener
        private let body: Data
        private let sendBytes: Int
        private(set) var port: UInt16 = 0
        private let notes = OSAllocatedUnfairLock<[String]>(initialState: [])
        /// The ranges asked and what each got, for the witness's message.
        var log: [String] { notes.withLock { $0 } }

        init(body: Data, sendBytes: Int) throws {
            self.body = body
            self.sendBytes = sendBytes
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in serve(connection) }
            port = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [self] state in
                    let first = once.withLock { done in
                        let was = done
                        if case .ready = state { done = true } else if case .failed = state { done = true }
                        return !was && done
                    }
                    if first, case .ready = state { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    if first, case .failed(let error) = state { continuation.resume(throwing: error) }
                }
                listener.start(queue: .global())
            }
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let range = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }.map(String.init) ?? ""
                let total = body.count
                var lower = 0, upper = total - 1
                if let eq = range.range(of: "bytes=") {
                    let parts = range[eq.upperBound...].split(separator: "-", omittingEmptySubsequences: false)
                    lower = Int(parts.first ?? "") ?? 0
                    if parts.count > 1, let given = Int(parts[1]) { upper = min(given, total - 1) }
                }
                let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\n"
                    + "Content-Range: bytes \(lower)-\(upper)/\(total)\r\nContent-Length: \(upper - lower + 1)\r\n\r\n"
                let served = upper - lower < 65_536 ? "all" : lower < sendBytes ? "cut" : "closed"
                let note = "\(lower)-\(upper) \(served)"
                notes.withLock { $0.append(note) }
                // The length probe and the tail are small reads and are served.
                if upper - lower < 65_536 {
                    connection.send(content: Data(header.utf8) + body.subdata(in: lower..<(upper + 1)),
                                    completion: .contentProcessed { _ in })
                } else if lower < sendBytes {
                    let chunk = body.subdata(in: lower..<min(upper + 1, sendBytes))
                    connection.send(content: Data(header.utf8) + chunk, completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func wav(seconds: Int) -> Data {
        let rate = 22_050
        var samples = Data(capacity: rate * seconds * 2)
        for index in 0..<(rate * seconds) {
            let value = Int16(3000 * sin(Double(index) * 0.05))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func half(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); word(UInt32(36 + samples.count)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); word(16); half(1); half(1); word(UInt32(rate)); word(UInt32(rate * 2)); half(2); half(16)
        data.append(contentsOf: Array("data".utf8)); word(UInt32(samples.count)); data.append(samples)
        return data
    }

    /// The real player, not the rule: a stream that stops delivering leaves
    /// a ready item waiting with the stall reason, and the model says so; a
    /// pause ends the wait. Measured here at the start (the player never
    /// began with the cut stream); mid-play the same reason stands (measured
    /// before with a cut after thirty seconds of audio).
    @Test("a stream that stops delivering is reported by the model as waiting for the stream, a pause ends it", .needsAudio)
    func aStreamThatStopsIsAWait() async throws {
        let body = wav(seconds: 60)
        let host = try CuttingHost(body: body, sendBytes: 44 + 44_100 * 20)
        try await host.start()
        defer { host.stop() }
        let duration = Double(body.count - 44) / 44_100
        let tracks = [ABSAudioTrack(index: 0, startOffset: 0, duration: duration,
                                    contentUrl: "http://127.0.0.1:\(host.port)/stall.wav", metadata: nil)]
        let detail = LibraryItemDetail(id: "stall-\(UUID().uuidString)",
                                       media: LibraryItemMedia(metadata: nil, duration: duration, chapters: nil, tracks: tracks),
                                       userMediaProgress: nil)
        let model = PlayerViewModel(provider: FailedLoadTests.MixedProvider(), localTracks: { _ in [:] }, isOnline: { true })
        defer { model.stop() }
        await model.load(item: detail)
        model.play()
        var rounds = 0
        while !model.waitsOnTheStream, rounds < 120 {
            await wait(0.25)
            rounds += 1
        }
        // Let the wait settle past the first bytes, then read the player.
        await wait(3)
        let ready = model.player?.currentItem?.status == .readyToPlay
        let reason = model.player?.reasonForWaitingToPlay
        let seen = "status \(model.player?.timeControlStatus.rawValue ?? -1), reason \(reason?.rawValue ?? "-"), host \(host.log)"
        #expect(ready, "the precondition: the item loaded, so the wait is on the stream, not a failure; \(seen)")
        #expect(reason == .toMinimizeStalls, "the precondition: the player waits for the stall reason; \(seen)")
        #expect(model.waitsOnTheStream, "a stream that stopped delivering did not read as a wait; \(seen)")
        #expect(model.isPlaying, "the player no longer says it plays, so the wait would be its own sign; \(seen)")
        model.pause()
        rounds = 0
        while model.waitsOnTheStream, rounds < 40 {
            await wait(0.25)
            rounds += 1
        }
        #expect(!model.waitsOnTheStream, "a pause did not end the wait")
    }
}
#endif
