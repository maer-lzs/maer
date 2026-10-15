// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
import Combine
import UIKit
@testable import Maer

/// The work of the per-second tick while playback runs quietly: no jump,
/// no change of rate, chapter, track or state. Counted over a few seconds
/// of real playback of a generated tone.
@MainActor
struct TickWorkTests {

    func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tick-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = 0.1 * sinf(Float(i) * 0.05) }
        }
        try file.write(from: buffer)
        return url
    }

    func waitFor(_ condition: () -> Bool, seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// What the tick did over `seconds` of quiet playback.
    struct Work {
        var ticks = 0
        var nowPlayingWrites = 0
        var artworkBuilds = 0
        var publications = 0
        var statsMerges = 0
    }

    func quietWork(seconds: Double) async throws -> Work {
        let file = try tone(seconds: seconds + 4)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book("tick-\(UUID().uuidString)", path: file.path, size: 1, seconds: seconds + 4))
        model.artworkImage = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        model.play()
        await waitFor { model.currentTime >= 1 }
        try #require(model.isPlaying && model.currentTime >= 1, "the precondition: the tone plays")

        var work = Work()
        var publications = 0
        let watch = model.objectWillChange.sink { _ in publications += 1 }
        let writes = model.nowPlayingWrites, artworks = model.artworkBuilds
        let merges = ListeningStatsStore.shared.merges
        let start = model.currentTime
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        watch.cancel()
        work.ticks = Int((model.currentTime - start).rounded())
        work.nowPlayingWrites = model.nowPlayingWrites - writes
        work.artworkBuilds = model.artworkBuilds - artworks
        work.publications = publications
        work.statsMerges = ListeningStatsStore.shared.merges - merges
        model.stop()
        return work
    }

    @Test("ruhige Wiedergabe: der Tick schreibt die Sperrbildschirm-Anzeige nicht neu und baut kein Artwork", .needsAudio)
    func quietPlaybackWritesNoLockScreen() async throws {
        let work = try await quietWork(seconds: 3)
        #expect(work.ticks >= 2, "the precondition: the tone played on: \(work)")
        #expect(work.nowPlayingWrites == 0, "lock screen writes per quiet second: \(work)")
        #expect(work.artworkBuilds == 0, "artworks built per quiet second: \(work)")
    }

    /// The model publishes a value only when it changed: in quiet playback
    /// that is the running time, once a second, and nothing else.
    @Test("ruhige Wiedergabe: das Modell publiziert nur die laufende Zeit, einmal je Sekunde", .needsAudio)
    func quietPlaybackPublishesOnlyTheTime() async throws {
        let work = try await quietWork(seconds: 3)
        #expect(work.ticks >= 2, "the precondition: the tone played on: \(work)")
        #expect(work.publications <= work.ticks + 1, "publications per quiet second: \(work)")
    }

    /// What the lock screen shows still moves at once with every change: a
    /// new chapter on the tick it begins, a jump with the jump. Read from
    /// what this model wrote, not from the shared info centre, which other
    /// suites write as well.
    @Test("Kapitelwechsel und Sprung: die Sperrbildschirm-Anzeige stimmt sofort, Kapitel und Position", .needsAudio)
    func chaptersAndJumpsReachTheLockScreenAtOnce() async throws {
        let file = try tone(seconds: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        let book = LibraryItemDetail(
            id: "tick-chapters-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 10, chapters: [
                ABSChapter(id: 0, start: 0, end: 2, title: "Eins"),
                ABSChapter(id: 1, start: 2, end: 10, title: "Zwei"),
            ], tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: 10, contentUrl: file.path, metadata: nil)]),
            userMediaProgress: nil)
        await model.load(item: book)
        model.play()
        await waitFor { model.currentChapter?.title == "Zwei" }
        #expect(model.currentChapter?.title == "Zwei", "the precondition: the second chapter began")
        #expect(model.lastNowPlaying?.fields.subtitle.contains("Zwei") == true,
                "the new chapter reached the lock screen on its tick: \(String(describing: model.lastNowPlaying))")

        await model.seek(to: 7)
        let written = try #require(model.lastNowPlaying)
        #expect(abs(written.elapsed - 7) < 0.5, "the jump reached the lock screen with the jump: \(written.elapsed)")
        model.stop()
    }
}
#endif
