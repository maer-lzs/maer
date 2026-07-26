// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// #51/W1 (class B): change detection via content identity, never via count.
struct ContentTokenTests {
    @Test("Same content, any order: same token")
    func orderInsensitive() {
        #expect(ContentToken.of(["a", "b", "c"]) == ContentToken.of(["c", "a", "b"]))
        #expect(ContentToken.of(Set(["a", "b"])) == ContentToken.of(["b", "a"]))
    }

    @Test("Swapped element at equal count: different token (the class-B failure)")
    func swappedContentChangesToken() {
        #expect(ContentToken.of(["feedA", "feedB"]) != ContentToken.of(["feedA", "feedC"]))
    }

    @Test("Empty and growth")
    func emptyAndGrowth() {
        #expect(ContentToken.of([String]()) == 0)
        #expect(ContentToken.of(["a"]) != ContentToken.of([String]()))
        #expect(ContentToken.of(["a", "b"]) != ContentToken.of(["a"]))
    }
}

/// Drive mode: the one-button sleep cycle off→15→30→60→off.
struct DriveModeSleepTests {
    @Test("Sleep cycle steps")
    func cycle() {
        #expect(DriveModeView.nextSleepStep(active: false, current: nil) == 15)
        #expect(DriveModeView.nextSleepStep(active: true, current: 15 * 60) == 30)
        #expect(DriveModeView.nextSleepStep(active: true, current: 29 * 60) == 60)
        #expect(DriveModeView.nextSleepStep(active: true, current: 60 * 60) == nil)
    }
}

/// Listen log (2825f15): played transitions land show-independently, the
/// unplayed tombstone survives, only a NEWER play flips it back.
@MainActor
struct PodcastListenLogTests {
    private func write(_ guid: String, time: Double, ts: Double) {
        UserDefaults.standard.set([time, ts], forKey: AppStorageKeys.localPosition(guid))
    }

    @Test("Played entry survives; unplayed tombstones; newer play flips back")
    func lifecycle() {
        let log = PodcastListenLog.shared
        log._resetForTest()
        let guid = "rss:test-log-1"
        defer { UserDefaults.standard.removeObject(forKey: AppStorageKeys.localPosition(guid)) }
        write(guid, time: 600, ts: 1_000)
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "Show", feedURL: "https://f")
        #expect(log.entries[guid]?.isPlayed == true)
        #expect(log.entries[guid]?.showTitle == "Show")
        log.markUnplayed(guid: guid)
        #expect(log.entries[guid]?.isPlayed == false)
        // An OLD position (reconcile echo) must NOT resurrect "played".
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "Show", feedURL: "https://f")
        #expect(log.entries[guid]?.isPlayed == false)
        // A NEWER real play-through flips it back.
        write(guid, time: 600, ts: Date().timeIntervalSince1970 * 1000 + 10_000)
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "Show", feedURL: "https://f")
        #expect(log.entries[guid]?.isPlayed == true)
        // In-progress never logs.
        let guid2 = "rss:test-log-2"
        defer { UserDefaults.standard.removeObject(forKey: AppStorageKeys.localPosition(guid2)) }
        write(guid2, time: 100, ts: 2_000)
        log.noteIfPlayed(guid: guid2, duration: 600, episodeTitle: "E2", showTitle: "S", feedURL: "")
        #expect(log.entries[guid2] == nil)
    }
}
#endif
