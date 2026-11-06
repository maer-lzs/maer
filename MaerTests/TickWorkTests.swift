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
        var clockPublications = 0
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
        var clockPublications = 0
        let watch = model.objectWillChange.sink { _ in publications += 1 }
        let watchClock = model.clock.objectWillChange.sink { _ in clockPublications += 1 }
        let writes = model.nowPlayingWrites, artworks = model.artworkBuilds
        let merges = ListeningStatsStore.shared.merges
        let start = model.currentTime
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        watch.cancel()
        watchClock.cancel()
        work.clockPublications = clockPublications
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

    /// A value is published only when it changed, and the running time on
    /// its own clock: in quiet playback the model publishes nothing, the
    /// clock once a second. A surface that observes the model and not the
    /// clock is not woken.
    @Test("ruhige Wiedergabe: das Modell publiziert nichts, die Uhr die laufende Zeit, einmal je Sekunde", .needsAudio)
    func quietPlaybackPublishesOnlyTheTime() async throws {
        let work = try await quietWork(seconds: 3)
        #expect(work.ticks >= 2, "the precondition: the tone played on: \(work)")
        #expect(work.publications == 0, "model publications per quiet second: \(work)")
        #expect(work.clockPublications >= 2 && work.clockPublications <= work.ticks + 1,
                "the clock publishes the time once a second: \(work)")
    }

    /// The views read the model's time only through the clock in a leaf.
    /// What still reads it directly, per file, with why: none of it in a
    /// body that observes the model.
    static let directTimeReads: [String: (count: Int, reason: String)] = [
        "BookmarksSheet.swift": (1, "an action: the position at the tap, never drawn"),
        "PlayerView.swift": (1, "an action: where a drag of the slider begins"),
    ]

    /// The drive page observes the coordinator, which does not move with the
    /// running time: its progress, its remaining time and its live time are
    /// each a leaf of the clock, so they move every second.
    @Test("die Fahrseite zeichnet Fortschritt, Restzeit und Live-Zeit aus der Uhr, jede Sekunde", .needsTheSources)
    func theDrivePageDrawsTheTimeFromTheClock() throws {
        let url = SourceTree.root.appendingPathComponent("Sources/Views/DriveModeView.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
        #expect(code.components(separatedBy: "PlaybackTimeReader(clock: vm.clock)").count - 1 == 2,
                "the progress or the live time is no longer a leaf of the clock")
        #expect(!code.contains(".currentTime"), "the drive page reads the model's time past the clock")
        #expect(DriveModeView.remainingText(time: 600, duration: 4200) == "-1:00 h")
        #expect(DriveModeView.remainingText(time: 3000, duration: 3600) == "-" + DurationText.length(minutes: 10))
        #expect(DriveModeView.elapsedText(3900) == "1:05 h")
        #expect(DriveModeView.elapsedText(-5) == DurationText.length(minutes: 0))
    }

    /// Below an hour the drive page writes minutes in the app's one duration
    /// form (in German "12 Min."), from an hour on its clock form stays.
    @Test("die Fahrseite schreibt Minuten unter einer Stunde in der einen Form der App, die Uhrform ab einer Stunde bleibt")
    func theDrivePageWritesMinutesByTheRule() {
        #expect(DriveModeView.elapsedText(12 * 60 + 30) == DurationText.length(minutes: 12))
        #expect(DriveModeView.remainingText(time: 0, duration: 12 * 60 + 30) == "-" + DurationText.length(minutes: 12))
        #expect(DriveModeView.elapsedText(3600) == "1:00 h", "an hour keeps the clock form")
    }

    /// Every read of a `.currentTime` property in a view, whatever the model
    /// is called; a stored progress (`progress?.currentTime`) is a saved
    /// position, not the running time, and a call `currentTime()` is the
    /// player's.
    nonisolated static func modelTimeReads(in code: String) -> Int {
        code.matches(of: #/(\w+)\??\.currentTime\b(?!\()/#)
            .filter { !$0.output.1.lowercased().hasSuffix("progress") }
            .count
    }

    @Test("die Ansichten lesen die Zeit des Modells nur ueber die Uhr; jede andere Stelle ist je Datei gezaehlt, mit Grund", .needsTheSources)
    func viewsReadTheTimeThroughTheClock() {
        var counts: [String: Int] = [:]
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources/Views")) where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("unreadable: \(SourceTree.relativePath(of: url))")
                continue
            }
            let hits = Self.modelTimeReads(in: SyncContractFenceTests.stripped(text))
            if hits > 0 { counts[url.lastPathComponent] = hits }
        }
        #expect(Self.modelTimeReads(in: "let t = player.currentTime") == 1, "a model under another name slips through")
        #expect(Self.modelTimeReads(in: "let t = model?.currentTime ?? 0") == 1)
        #expect(Self.modelTimeReads(in: "x(entry.progress?.currentTime, cached?.userMediaProgress?.currentTime)") == 0,
                "a stored progress is not the running time")
        #expect(Self.modelTimeReads(in: "let t = avPlayer.currentTime()") == 0, "the player's call is not the model's time")
        #expect(StockDrift.findings(counts: counts, stock: Self.directTimeReads.mapValues(\.count)) == [],
                "a view reads the model's time past the clock, or a stock above the count")
        #expect(Self.directTimeReads.values.allSatisfy { !$0.reason.isEmpty })
    }

    @Test("ruhige Wiedergabe: die Statistik fuehrt die Toepfe nicht je Sekunde zusammen", .needsAudio)
    func quietPlaybackMergesNoPots() async throws {
        let work = try await quietWork(seconds: 3)
        #expect(work.ticks >= 2, "the precondition: the tone played on: \(work)")
        #expect(work.statsMerges == 0, "merges per quiet second while nobody reads: \(work)")
    }

    private final class QuietCarrier: StatsCarrier {
        let name = "quiet-fake"
        var hasRoomLimit = false
        let hasDeliveredFirst = true
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {}
        func pots() -> [String: ListeningStatsData] { [:] }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    /// Summed on read: seconds added without a reader merge nothing, the
    /// next read merges once and carries every second.
    @Test("die Statistik fuehrt beim Lesen zusammen, einmal, mit jeder Sekunde")
    func theStatsMergeWhenRead() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-stats-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stats = ListeningStatsStore(carrier: QuietCarrier(),
                                        database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let id = "tick:merge:\(UUID().uuidString)"
        _ = stats.data
        let before = stats.merges
        for _ in 0..<5 { stats.addSeconds(1, itemId: id) }
        #expect(stats.merges == before, "no reader, no merge")
        #expect(stats.data.secondsPerItem[id] == 5, "the read carries every second")
        #expect(stats.merges == before + 1, "one merge for the read")
        _ = stats.data
        #expect(stats.merges == before + 1, "a second read without a change merges nothing")
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
