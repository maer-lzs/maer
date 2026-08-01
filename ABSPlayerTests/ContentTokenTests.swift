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

/// Drive mode (9357955 + 9941a9a): the pure route-change decision and the
/// portrait transport fit. (The sleep cycle left with its button — 0693e05.)
struct DriveModeTests {
    @Test("Auto-start requires the opt-in toggle — connect alone never enters")
    func autoStartOptIn() {
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: false, rememberedUID: "car-1",
            connectedUIDs: ["car-1"], isActive: false) == nil)
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: true, rememberedUID: "car-1",
            connectedUIDs: ["car-1"], isActive: false) == .enter)
    }

    @Test("Matching is STRICTLY the chosen UID — any other A2DP is a stranger")
    func strictUID() {
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: true, rememberedUID: "car-1",
            connectedUIDs: ["headphones-9", "speaker-2"], isActive: false) == nil)
        // No/orphaned choice: NEVER anything, however much connects.
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: true, rememberedUID: nil,
            connectedUIDs: ["headphones-9"], isActive: false) == nil)
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: true, rememberedUID: "",
            connectedUIDs: ["headphones-9"], isActive: true) == nil)
    }

    @Test("Disconnect of the chosen device exits an active mode (toggle-independent)")
    func exitOnDisconnect() {
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: false, rememberedUID: "car-1",
            connectedUIDs: [], isActive: true) == .exit)
        // Already active + still connected → nothing.
        #expect(DriveModeController.routeChangeAction(
            autoStartEnabled: true, rememberedUID: "car-1",
            connectedUIDs: ["car-1"], isActive: true) == nil)
    }

    @Test("Transport row fits portrait phone widths (it overflowed before)")
    func transportFits() {
        // Natural sizes fit → no scaling (landscape column, wide portrait/iPad).
        #expect(DriveModeView.transportScale(availableWidth: 800, landscape: true) == 1)
        #expect(DriveModeView.transportScale(availableWidth: 600, landscape: false) == 1)
        // iPhone portrait (393 pt − padding = 345): scaled so the row FITS.
        let scale = DriveModeView.transportScale(availableWidth: 345, landscape: false)
        #expect(scale < 1)
        let row = (180 + 2 * 110 + 2 * 32) * scale
        #expect(row <= 345.5)
        // Tap surfaces stay glanceable (≥ 60 pt even at the 0.55 floor).
        #expect(110 * DriveModeView.transportScale(availableWidth: 200, landscape: false) >= 60)
        #expect(DriveModeView.transportScale(availableWidth: 0, landscape: false) == 1)
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
