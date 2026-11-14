// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import AVFoundation
import Foundation
import Network
import os
import Testing
@testable import Maer

/// What the "Continue" widget shows of the snapshot, home screen and lock
/// screen alike (`WidgetLine`), and what the app writes for each kind.
@MainActor
struct WidgetLineTests {
    private func snapshot(_ id: String, symbol: String?, live: Bool?) -> WidgetSnapshot {
        WidgetSnapshot(itemId: id, title: "Title", author: nil, fraction: 0.25, remainingText: "1 h",
                       isPlaying: false, steps: nil, savedAt: 1000, kindSymbol: symbol, isLive: live)
    }

    @Test("the line per kind: audiobook, episode, song with remaining time and share, a station live without both, an old snapshot with the symbol without a kind")
    func theLineOfEachKind() {
        let now = Date(timeIntervalSince1970: 2000)
        for (id, symbol) in [("book-1", "book.closed"), ("rss:ep-1", "mic"), ("sub:song:1", "music.note")] {
            let line = WidgetLine.of(snapshot(id, symbol: symbol, live: false), at: now)
            #expect(line == WidgetLine(symbol: symbol, title: "Title", fraction: 0.25, remainingText: "1 h", isLive: false), "\(id)")
        }
        let station = WidgetLine.of(snapshot("radio:s-1", symbol: "dot.radiowaves.left.and.right", live: true), at: now)
        #expect(station == WidgetLine(symbol: "dot.radiowaves.left.and.right", title: "Title", fraction: nil,
                                      remainingText: nil, isLive: true))
        let old = WidgetLine.of(snapshot("book-1", symbol: nil, live: nil), at: now)
        #expect(old == WidgetLine(symbol: WidgetLine.unknownKindSymbol, title: "Title", fraction: 0.25,
                                  remainingText: "1 h", isLive: false), "a snapshot without the kind reads as before")
    }

    /// A file in the form without the kind and without live, steps and
    /// all: a literal, no round trip.
    @Test("the file of today's form reads: without kind and without live, with steps")
    func theFileOfTodayReads() throws {
        let file = #"{"itemId":"book-1","title":"t","author":"a","fraction":0.5,"remainingText":"noch 1 Std.","isPlaying":true,"#
            + #""steps":[{"fraction":0.5,"remainingText":"noch 1 Std."},{"fraction":0.51,"remainingText":"noch 59 Min."}],"savedAt":1000}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(file.utf8))
        #expect(snapshot.kindSymbol == nil && snapshot.isLive == nil)
        let line = WidgetLine.of(snapshot, at: Date(timeIntervalSince1970: 1000 + 61))
        #expect(line.fraction == 0.51 && line.remainingText == "noch 59 Min." && !line.isLive)
    }

    @Test("without a known length a title writes nothing, a station always, live and without share; a title with a length writes share, remaining time and steps from position, length and rate")
    func whatTheWriterWrites() {
        let text: (Double) -> String? = { "\(Int($0))" }
        let book = WidgetSnapshot.of(itemId: "book-1", title: "t", author: "a", kindSymbol: "book.closed", isLive: false,
                                     position: 600, duration: 3600, rate: 1.5, isPlaying: true, now: 1000, minutesAhead: 60,
                                     remaining: text)
        #expect(book?.fraction == 600.0 / 3600)
        #expect(book?.remainingText == "3000")
        #expect(book?.steps == WidgetSnapshot.steps(position: 600, duration: 3600, rate: 1.5, minutes: 60, remaining: text))
        #expect(book?.isPlaying == true && book?.savedAt == 1000 && book?.author == "a" && book?.title == "t")
        #expect(book?.isLive == false && book?.kindSymbol == "book.closed")
        let paused = WidgetSnapshot.of(itemId: "book-1", title: "t", author: nil, kindSymbol: "book.closed", isLive: false,
                                       position: 600, duration: 3600, rate: 1, isPlaying: false, now: 1000, minutesAhead: 60,
                                       remaining: text)
        #expect(paused?.steps == nil, "a paused title carries steps")
        let none = WidgetSnapshot.of(itemId: "book-1", title: "t", author: nil, kindSymbol: "book.closed", isLive: false,
                                     position: 3, duration: 0, rate: 1, isPlaying: true, now: 1000, minutesAhead: 60,
                                     remaining: { _ in "x" })
        #expect(none == nil, "a title of no known length wrote a snapshot")
        let station = WidgetSnapshot.of(itemId: "radio:s-1", title: "s", author: nil, kindSymbol: "dot.radiowaves.left.and.right",
                                        isLive: true, position: 40, duration: 40, rate: 1, isPlaying: false, now: 1000,
                                        minutesAhead: 60, remaining: { _ in "x" })
        #expect(station?.isLive == true && station?.fraction == 0 && station?.remainingText == nil && station?.steps == nil,
                "a station written by its length: \(String(describing: station))")
    }

    /// The real player, a book: the pause writes the fields as position
    /// and length give them, no steps, and the book's kind.
    @Test("an audiobook writes the same snapshot after the pause as before, plus its kind", .needsAudio)
    func aBookWritesTheSameSnapshot() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        if let url = WidgetSnapshot.snapshotURL { try? FileManager.default.removeItem(at: url) }
        let id = "widget-line-\(UUID().uuidString)"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.play()
        await ticks.waitFor { model.currentTime >= 2 }
        model.pause()
        let written = try #require(WidgetSnapshot.load(), "the precondition: the pause wrote a snapshot")
        let position = model.currentTime
        #expect(written.itemId == id)
        #expect(written.fraction == min(max(position / model.duration, 0), 1))
        #expect(written.remainingText == DurationText.remaining(seconds: max(model.duration - position, 0)))
        #expect(!written.isPlaying && written.steps == nil && written.savedAt != nil)
        #expect(written.kindSymbol == "book.closed" && written.isLive == false)
        model.stop()
    }

    /// A station from a host that sends without a length and without an
    /// end, the way an Icecast station does: the player's duration grows
    /// with the position, and the pause still writes it as live.
    @Test("a station without a length writes live after the pause, without a full bar and without remaining time", .needsAudio)
    func aPausedStationIsLive() async throws {
        let host = try EndlessHost(chunk: try adts(seconds: 0.5))
        try await host.start()
        defer { host.stop() }
        if let url = WidgetSnapshot.snapshotURL { try? FileManager.default.removeItem(at: url) }
        let station = LibraryItemDetail(
            id: "radio:widget-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: nil, chapters: nil, tracks: [
                ABSAudioTrack(index: 0, startOffset: 0, duration: nil,
                              contentUrl: "http://127.0.0.1:\(host.port)/stream", metadata: nil),
            ]),
            userMediaProgress: nil)
        let model = PlayerViewModel(provider: FailedLoadTests.MixedProvider(), localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: station)
        model.play()
        let start = Date()
        while model.currentTime < 3, Date().timeIntervalSince(start) < 20 { try await Task.sleep(for: .milliseconds(200)) }
        #expect(model.currentTime >= 3 && model.duration > 0, "the precondition: the station played and its duration grew")
        model.pause()
        let written = try #require(WidgetSnapshot.load(), "the pause wrote no snapshot for the station")
        #expect(written.itemId == station.id)
        #expect(written.isLive == true, "the station was written by its length")
        #expect(written.fraction != 1 && written.remainingText == nil, "the widget shows the station as finished")
        #expect(written.kindSymbol == "dot.radiowaves.left.and.right")
        #expect(WidgetLine.of(written, at: Date()).isLive, "small and medium show the station without live")
        model.stop()
    }

    /// Sends the same chunk again and again with no length; ends after a
    /// few minutes so a forgotten host does not run on. Unchecked because
    /// the listener and its connections are only touched on the listener's
    /// own queue after start.
    nonisolated final class EndlessHost: @unchecked Sendable {
        private let listener: NWListener
        private let chunk: Data
        private(set) var port: UInt16 = 0

        init(chunk: Data) throws {
            self.chunk = chunk
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] _, _, _, _ in
                let header = "HTTP/1.0 200 OK\r\nContent-Type: audio/aac\r\nCache-Control: no-cache\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [self] _ in pump(connection, round: 0) })
            }
        }

        private func pump(_ connection: NWConnection, round: Int) {
            guard round < 400 else {
                connection.cancel()
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [self] error in
                // A closed connection ends the pump; the player asks anew.
                if error == nil {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in pump(connection, round: round + 1) }
                }
            })
        }
    }

    /// The description in the widget gallery and in "Edit Widget": the
    /// English key says "tap", the German value says it the same way.
    @Test("the description of Continue Listening: with a tap, in the widget and in the catalog", .needsTheSources)
    func theDescriptionSaysOneTap() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains(".description(\"The last thing you played, one tap away.\")"))
        let catalog = try StringCatalogOrderTests.entries()
        let german = ((catalog["The last thing you played, one tap away."]?["localizations"] as? [String: Any])?["de"]
            as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == "Das zuletzt Gehörte, mit einem Tippen.")
    }

    /// Half a second of tone as AAC in ADTS frames, the form a station
    /// sends.
    private func adts(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-line-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: frames))
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) { data[index] = 0.1 * sinf(Float(index) * 0.05) }
        }
        try file.write(from: buffer)
        return try Data(contentsOf: url)
    }
}
#endif
