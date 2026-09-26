// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

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

/// Drive mode: the pure route-change decision and the
/// portrait transport fit. (The sleep cycle left with its button.)
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

    @Test("a74c903: numbered skip glyph for SF-supported intervals, nil else")
    func skipGlyphs() {
        #expect(DriveModeView.skipGlyphName(interval: 30, forward: true) == "goforward.30")
        #expect(DriveModeView.skipGlyphName(interval: 15, forward: false) == "gobackward.15")
        #expect(DriveModeView.skipGlyphName(interval: 60, forward: true) == "goforward.60")
        // No SF symbol → nil (caller falls back to the two-line form).
        #expect(DriveModeView.skipGlyphName(interval: 20, forward: true) == nil)
        #expect(DriveModeView.skipGlyphName(interval: 12.5, forward: false) == nil)
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

/// Listen log: played transitions land show-independently, the
/// unplayed tombstone survives, only a NEWER play flips it back.
@MainActor
struct PodcastListenLogTests {
    @Test("V6 history: tombstones hidden, newest play first")
    func historyDerivation() {
        func entry(_ guid: String, played: Double, unplayed: Double? = nil) -> PodcastListenLog.Entry {
            PodcastListenLog.Entry(guid: guid, episodeTitle: guid, showTitle: "S",
                                   feedURL: "https://f", duration: 100,
                                   playedAt: played, unplayedAt: unplayed)
        }
        let out = PodcastListenLog.historyList([
            "a": entry("a", played: 1_000),
            "b": entry("b", played: 3_000),
            "c": entry("c", played: 2_000, unplayed: 2_500),   // tombstoned
            "d": entry("d", played: 4_000, unplayed: 3_500),   // newer play wins
        ])
        #expect(out.map(\.guid) == ["d", "b", "a"])
    }

    private func write(_ guid: String, time: Double, ts: Double) {
        ListeningStore.store(guid, entry: [time, ts])
    }

    @Test("Played entry survives; unplayed tombstones; newer play flips back")
    func lifecycle() {
        let log = PodcastListenLog.shared
        log._resetForTest()
        let guid = "rss:test-log-1"
        defer { ListeningStore.clearBackup(guid) }
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
        defer { ListeningStore.clearBackup(guid2) }
        write(guid2, time: 100, ts: 2_000)
        log.noteIfPlayed(guid: guid2, duration: 600, episodeTitle: "E2", showTitle: "S", feedURL: "")
        #expect(log.entries[guid2] == nil)
    }

    @Test("49dc2c3: bulk-booked entries answer no WHEN; a real transition upgrades them")
    func synthesizedStamps() {
        let log = PodcastListenLog.shared
        log._resetForTest()
        let guid = "rss:test-log-synth"
        defer { ListeningStore.clearBackup(guid) }
        write(guid, time: 600, ts: 1_000)
        // The bulk pass (backfill/rescan) books the fact, not a listen time.
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "S",
                         feedURL: "https://f", synthesized: true)
        #expect(log.entries[guid]?.isPlayed == true)
        #expect(log.entries[guid]?.hasObservedTime == false)
        // A later REAL transition (newer stamp) upgrades the entry…
        write(guid, time: 600, ts: 5_000)
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "S",
                         feedURL: "https://f")
        #expect(log.entries[guid]?.hasObservedTime == true)
        // …and a later bulk pass never downgrades it back.
        write(guid, time: 600, ts: 9_000)
        log.noteIfPlayed(guid: guid, duration: 600, episodeTitle: "Ep", showTitle: "S",
                         feedURL: "https://f", synthesized: true)
        #expect(log.entries[guid]?.hasObservedTime == true)
    }

    @Test("b81949f: the picker unites connected route, paired inputs and the remembered device")
    func pickerList() {
        let route = [(uid: "car-1", name: "VW Golf", portType: "CarAudio"),
                     (uid: "spk", name: "Speaker", portType: "Speaker")]
        let inputs = [(uid: "hfp-2", name: "Autoradio", portType: "BluetoothHFP"),
                      (uid: "car-1", name: "VW Golf", portType: "BluetoothHFP"),
                      (uid: "mic", name: "iPhone Mikrofon", portType: "MicrophoneBuiltIn")]
        let list = DriveModeController.pickerList(
            routeOutputs: route, availableInputs: inputs,
            remembered: (uid: "old-3", name: "Altes Kit"))
        // Connected first, paired devices next, remembered kept alive; the
        // built-in speaker and microphone never appear.
        #expect(list.map(\.uid) == ["car-1", "hfp-2", "old-3"])
        // A remembered device that IS present is not duplicated.
        let noDupe = DriveModeController.pickerList(
            routeOutputs: route, availableInputs: [],
            remembered: (uid: "car-1", name: "VW Golf"))
        #expect(noDupe.map(\.uid) == ["car-1"])
        // Nothing anywhere ⇒ empty (the settings then show the hint).
        #expect(DriveModeController.pickerList(routeOutputs: [], availableInputs: [],
                                               remembered: nil).isEmpty)
        // An empty remembered uid is not an entry.
        #expect(DriveModeController.pickerList(routeOutputs: [], availableInputs: [],
                                               remembered: (uid: "", name: "")).isEmpty)
    }

    @Test("01fab43: car-audio candidates — external routes only, built-ins drop")
    func carCandidates() {
        let outputs = [
            (uid: "bt1", name: "VW Golf", portType: "BluetoothA2DPOutput"),
            (uid: "sp", name: "Speaker", portType: "Speaker"),
            (uid: "rc", name: "Receiver", portType: "Receiver"),
            (uid: "cp", name: "CarPlay", portType: "CarAudio"),
            (uid: "hfp", name: "Old Kit", portType: "BluetoothHFP"),
        ]
        let picked = DriveModeController.carAudioCandidates(outputs)
        #expect(picked.map(\.uid) == ["bt1", "cp", "hfp"])
        // Nothing external connected → empty (the settings show the hint).
        #expect(DriveModeController.carAudioCandidates(
            [(uid: "sp", name: "Speaker", portType: "Speaker")]).isEmpty)
    }
}
#endif