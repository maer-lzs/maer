// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cadence of the ten-second loop and of the widget, counted per hour
/// from the rules the loop asks (Platz 4).
@MainActor
struct CadenceTests {

    /// What the loop asks for in one hour, by path: its wake-ups, the
    /// server round, the poll of a foreign claim, the pot's pull at a
    /// carrier's cadence. The claim's heartbeat rides on the server round
    /// while playing.
    struct Hour: Equatable {
        var wakeUps = 0, serverRounds = 0, polls = 0, pulls = 0, heartbeats = 0
    }

    static func hour(playing: Bool, pullSeconds: Double, heartbeatSeconds: Double = 10) -> Hour {
        var hour = Hour()
        let ticks = Int(3600 / PlaybackClaimRules.tickSeconds)
        for tick in 1...ticks {
            hour.wakeUps += 1
            if PlaybackClaimRules.syncDue(tick: tick) { hour.serverRounds += 1 }
            if PlaybackClaimRules.pollDue(tick: tick, playing: playing) { hour.polls += 1 }
            if playing, PlaybackClaimRules.due(tick: tick, everySeconds: pullSeconds) { hour.pulls += 1 }
        }
        // The heartbeat is asked by the per-second tick while playing, at
        // the carrier's length.
        if playing {
            var last = 0.0
            for second in 1...3600 where PlaybackClaimRules.shouldRefreshClaim(
                lastClaimAtMs: last, nowMs: Double(second) * 1000, forced: false, heartbeatSeconds: heartbeatSeconds) {
                last = Double(second) * 1000
                hour.heartbeats += 1
            }
        }
        return hour
    }

    /// The numbers of the measuring table, held: a change of the cadence
    /// shows here first, and the takeover between devices depends on them.
    @Test("die Kadenz je Stunde und Weg, nach den Regeln der Schleife: Pause und Spielen, je Traeger")
    func theCadencePerHour() {
        #expect(Self.hour(playing: false, pullSeconds: 10) == Hour(wakeUps: 360, serverRounds: 120, polls: 120, pulls: 0, heartbeats: 0))
        #expect(Self.hour(playing: true, pullSeconds: 10) == Hour(wakeUps: 360, serverRounds: 120, polls: 360, pulls: 360, heartbeats: 360))
        #expect(Self.hour(playing: true, pullSeconds: 30) == Hour(wakeUps: 360, serverRounds: 120, polls: 360, pulls: 120, heartbeats: 360))
    }

    /// While playing, the widget runs on by itself: a step per minute for
    /// the next hour, from position, duration and rate.
    @Test("das Widget laeuft beim Spielen selbst weiter: ein Schritt je Minute aus Position, Dauer und Rate")
    func theWidgetRunsOnByItself() {
        let steps = WidgetSnapshot.steps(position: 600, duration: 3600, rate: 1.5, minutes: 60) { "\(Int($0))" }
        #expect(steps.count == 61)
        #expect(steps[0] == .init(fraction: 600.0 / 3600, remainingText: "3000"))
        #expect(steps[10] == .init(fraction: 1500.0 / 3600, remainingText: "2100"), "ten minutes at 1.5: 900 s further")
        #expect(steps[60] == .init(fraction: 1, remainingText: "0"), "never past the end")

        let saved = Date(timeIntervalSince1970: 1_000_000)
        let playing = WidgetSnapshot(itemId: "x", title: "t", author: nil, fraction: 600.0 / 3600, remainingText: "3000",
                                     isPlaying: true, steps: steps, savedAt: saved.timeIntervalSince1970)
        #expect(playing.shown(at: saved.addingTimeInterval(10 * 60 + 30)) == steps[10], "the step of the minute")
        #expect(playing.shown(at: saved.addingTimeInterval(5 * 3600)) == steps[60], "after the hour the last step holds")
        var paused = playing
        paused.isPlaying = false
        #expect(paused.shown(at: saved.addingTimeInterval(600)) == .init(fraction: 600.0 / 3600, remainingText: "3000"),
                "paused, the saved values")
    }

    /// An hour and a half of playback without a change of state: the tick
    /// asks the rule each second, renews the snapshot before its steps run
    /// out, and the widget shows the true position at every minute. Without
    /// the renewal it stood on the last step after the hour.
    @Test("anderthalb Stunden ohne Zustandswechsel: der Tick erneuert den Schnappschuss, das Widget zeigt jede Minute die wahre Stelle")
    func aLongPlaybackKeepsTheWidgetRunning() {
        let duration = 3.0 * 3600, start = 1_000_000.0
        func snapshot(at second: Double) -> WidgetSnapshot {
            let steps = WidgetSnapshot.steps(position: second, duration: duration, rate: 1,
                                             minutes: PlayerViewModel.widgetMinutesAhead) { _ in nil }
            return WidgetSnapshot(itemId: "x", title: "t", author: nil, fraction: second / duration, remainingText: nil,
                                  isPlaying: true, steps: steps, savedAt: start + second)
        }
        var current = snapshot(at: 0)
        var renewals = 0
        for second in stride(from: 0.0, through: 90 * 60, by: 1) {
            if WidgetSnapshot.needsRenewal(savedAt: current.savedAt, now: start + second,
                                           minutesAhead: PlayerViewModel.widgetMinutesAhead) {
                current = snapshot(at: second)
                renewals += 1
            }
            if second.truncatingRemainder(dividingBy: 60) == 0 {
                let shown = current.shown(at: Date(timeIntervalSince1970: start + second)).fraction
                #expect(abs(shown - second / duration) < 0.0001, "minute \(Int(second / 60)): shown \(shown)")
            }
        }
        #expect(renewals == 1, "an hour and a half needs one renewal, not one a minute: \(renewals)")
        #expect(!WidgetSnapshot.needsRenewal(savedAt: nil, now: start, minutesAhead: 60), "a paused snapshot is renewed")
        #expect(!WidgetSnapshot.needsRenewal(savedAt: start, now: start + 54 * 60, minutesAhead: 60))
        #expect(WidgetSnapshot.needsRenewal(savedAt: start, now: start + 55 * 60, minutesAhead: 60))
    }

    /// A snapshot written before the steps existed still reads and shows
    /// its saved values.
    @Test("ein Schnappschuss von vorher bleibt lesbar und zeigt seine Werte")
    func anOldSnapshotReads() throws {
        let old = #"{"itemId":"x","title":"t","fraction":0.25,"remainingText":"1 h","isPlaying":true}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.steps == nil && snapshot.savedAt == nil)
        #expect(snapshot.shown(at: Date()) == .init(fraction: 0.25, remainingText: "1 h"))
    }

    /// The tick does not reload the widget; a jump and a change of rate,
    /// which move what the widget runs on from, do.
    @Test("der Tick laedt das Widget nicht neu; ein Sprung und eine neue Rate schreiben den Schnappschuss", .needsAudio)
    func onlyStateChangesWriteTheWidget() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book("cadence-\(UUID().uuidString)", path: file.path, size: 1, seconds: 12))
        model.play()
        await ticks.waitFor { model.currentTime >= 1 }
        let afterPlay = model.widgetWrites
        // The tick's local save comes every five seconds and carried the
        // widget's write: six seconds of quiet playback hold at least one
        // of them, and the widget must not be written there.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        #expect(model.widgetWrites == afterPlay, "the tick wrote the widget")
        await model.seek(to: 5)
        #expect(model.widgetWrites == afterPlay + 1, "a jump writes the widget")
        model.setPlaybackRate(1.5)
        #expect(model.widgetWrites == afterPlay + 2, "a new rate writes the widget")
        model.stop()
    }
}
#endif
