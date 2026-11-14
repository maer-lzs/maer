// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AVFoundation
import Foundation
import Testing
@testable import Maer

struct SoundCoreTests {
    private let phonak = SoundRoute(portType: "BluetoothA2DPOutput", uid: "AA:BB:CC:DD:EE:FF-tacl", name: "Phonak Audéo")
    private let speaker = SoundRoute(portType: "Speaker", uid: "Speaker", name: "Speaker")

    @Test("the presets are data: unique ids, one gain per band, and off is flat")
    func presetsAreData() {
        let ids = SoundPresets.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SoundPresets.all.allSatisfy { $0.bandGainsDB.count == SoundPresets.bandCenters.count })
        #expect(SoundPresets.off.isFlat)
        #expect(SoundPresets.all.filter(\.isFlat).map(\.id) == ["off"], "only off leaves the bands alone")
        #expect(SoundPresets.preset("from a later build") == SoundPresets.off, "an unknown id plays as it comes")
    }

    @Test("the gain stays between 1 and the one limit")
    func gainIsClamped() {
        #expect(SoundSetting(presetID: "off", gain: 9).clampedGain == SoundSetting.gainLimit)
        #expect(SoundSetting(presetID: "off", gain: 0.2).clampedGain == 1)
        #expect(SoundSetting(presetID: "off", gain: .nan).clampedGain == 1)
        #expect(SoundSetting(presetID: "off", gain: 1.5).clampedGain == 1.5)
    }

    @Test("a setting is off only with a flat preset and no gain")
    func offMeansNothingToDo() {
        #expect(SoundSetting.off.isOff)
        #expect(!SoundSetting(presetID: "off", gain: 1.3).isOff)
        #expect(!SoundSetting(presetID: "speech", gain: 1).isOff)
        #expect(SoundSetting(presetID: "unknown", gain: 0.5).isOff)
    }

    @Test("the book: a device's own setting, else the default for other devices")
    func bookChoosesPerDevice() {
        let speech = SoundSetting(presetID: "speech", gain: 1.5)
        let louder = SoundSetting(presetID: "louder", gain: 1.3)
        var book = SoundBook()
        book.fallback = louder
        book = book.setting(speech, for: phonak)
        #expect(book.setting(for: phonak) == speech)
        #expect(book.setting(for: speaker) == louder, "an unknown device takes the default")
        #expect(book.setting(for: nil) == louder, "no route takes the default")
        book = book.noting(speaker)
        #expect(book.devices.count == 2)
        #expect(book.setting(for: speaker) == louder, "a noted device without its own setting follows the default")
    }

    @Test("noting a known device keeps its setting and takes the new name")
    func notingKeepsTheSetting() {
        let speech = SoundSetting(presetID: "speech", gain: 1.5)
        let renamed = SoundRoute(portType: phonak.portType, uid: "AA:BB:CC:DD:EE:FF-tacl", name: "Hörgerät links")
        let book = SoundBook().setting(speech, for: phonak).noting(renamed)
        #expect(book.devices.count == 1)
        #expect(book.devices[0].route.name == "Hörgerät links")
        #expect(book.setting(for: phonak) == speech)
    }

    @Test("removing a device lets it follow the default again")
    func removingFallsBack() {
        let book = SoundBook().setting(SoundSetting(presetID: "speech", gain: 1), for: phonak).removing(key: phonak.key)
        #expect(book.devices.isEmpty)
        #expect(book.setting(for: phonak) == .off)
    }

    @Test("the route key joins the kind of port and its id")
    func routeKey() {
        #expect(phonak.key == "BluetoothA2DPOutput|AA:BB:CC:DD:EE:FF-tacl")
        #expect(SoundRoute(portType: "CarAudio", uid: "Speaker", name: "x").key != speaker.key,
                "the same id on another kind of port is another device")
    }

    @Test("the book survives encoding, and an empty book is the default off")
    func bookCodable() throws {
        let book = SoundBook().setting(SoundSetting(presetID: "oldRecordings", gain: 1.7), for: phonak)
        let back = try JSONDecoder().decode(SoundBook.self, from: JSONEncoder().encode(book))
        #expect(back == book)
        #expect(SoundBook().setting(for: phonak).isOff)
    }

    @Test("no filter on a station or with a setting that does nothing")
    func reach() {
        let speech = SoundSetting(presetID: "speech", gain: 1)
        #expect(SoundReach.shouldTry(isRadio: false, setting: speech))
        #expect(!SoundReach.shouldTry(isRadio: true, setting: speech), "a station")
        #expect(!SoundReach.shouldTry(isRadio: false, setting: .off), "off")
    }

    @MainActor
    @Test("an item without an audio track takes no filter and says so", .needsAudio)
    func noTrackNoFilter() async throws {
        let state = SoundTapState()
        state.set(SoundSetting(presetID: "speech", gain: 1))
        // An asset with a track, but none of them audio.
        let composition = AVMutableComposition()
        try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) != nil,
                     "the precondition: the asset carries a track")
        let silent = AVPlayerItem(asset: composition)
        #expect(await SoundTap.attach(state, to: silent) == .noAudioTrack)
        #expect(silent.audioMix == nil)
    }

    @MainActor
    @Test("an item whose tracks cannot be read says so with the reason, apart from one without an audio track", .needsAudio)
    func unreadableTracksSayWhy() async throws {
        let state = SoundTapState()
        state.set(SoundSetting(presetID: "speech", gain: 1))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID().uuidString).m4a")
        try Data("not a media file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = AVPlayerItem(url: file)
        let outcome = await SoundTap.attach(state, to: item)
        guard case .tracksNotRead(let reason) = outcome else {
            Issue.record("an unreadable asset reads as \(outcome.line)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(outcome.line.contains("could not be read"))
    }

    @Test("old chains are freed when taps come and go under the same setting, not only when the setting changes")
    func registerAndUnregisterFree() {
        let state = SoundTapState()
        state.set(SoundSetting(presetID: "speech", gain: 1), now: 0)
        // One title after the other, each with its own tap, the setting unchanged.
        for title in 0..<5 {
            let slot = SoundSlot(sampleRate: 44100, channels: 2)
            let start = UInt64(title) * 10_000_000_000
            state.register(slot, now: start)
            state.unregister(slot, now: start + 1)
        }
        #expect(state.retiredCount <= 1, "chains of finished titles pile up: \(state.retiredCount)")
    }

    @MainActor
    @Test("an item with a track takes the filter once; a second attach finds the mix and leaves it", .needsAudio)
    func attachOnce() async throws {
        let file = try TickWorkTests().tone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = SoundTapState()
        state.set(SoundSetting(presetID: "speech", gain: 1))
        let item = AVPlayerItem(url: file)
        let first = Task { @MainActor in await SoundTap.attach(state, to: item) }
        let second = Task { @MainActor in await SoundTap.attach(state, to: item) }
        let outcomes = [await first.value, await second.value]
        #expect(outcomes.filter { $0 == .hung }.count == 1, "two calls at once hang one filter: \(outcomes)")
        #expect(outcomes.contains(.alreadyHung))
        #expect(item.audioMix != nil)
    }

    @Test("a band at 0 dB passes the signal, a band at 6 dB lifts its centre by 6 dB")
    func peakingResponse() {
        let flat = SoundMath.peaking(center: 1000, gainDB: 0, q: 1, sampleRate: 44100)
        #expect(abs(SoundMath.responseDB(flat, at: 1000, sampleRate: 44100)) < 0.001)
        #expect(abs(SoundMath.responseDB(flat, at: 100, sampleRate: 44100)) < 0.001)
        let lift = SoundMath.peaking(center: 1000, gainDB: 6, q: 1, sampleRate: 44100)
        #expect(abs(SoundMath.responseDB(lift, at: 1000, sampleRate: 44100) - 6) < 0.01)
        #expect(abs(SoundMath.responseDB(lift, at: 15000, sampleRate: 44100)) < 0.5, "far from the centre the band leaves the signal alone")
        let cut = SoundMath.peaking(center: 60, gainDB: -4, q: 1, sampleRate: 48000)
        #expect(abs(SoundMath.responseDB(cut, at: 60, sampleRate: 48000) + 4) < 0.01)
    }

    @Test("the chain holds five coefficients per band, and a centre above the sample rate's reach is held below it")
    func chain() {
        let speech = SoundPresets.preset("speech")
        #expect(SoundMath.chain(speech, sampleRate: 44100).count == 5 * SoundPresets.bandCenters.count)
        let low = SoundMath.peaking(center: 14000, gainDB: 3, q: 1, sampleRate: 22050)
        #expect(low.allSatisfy { $0.isFinite })
    }

    @Test("the limiter is linear below the knee and never passes the ceiling")
    func limiter() {
        #expect(SoundMath.limited(0.5) == 0.5)
        #expect(SoundMath.limited(-0.69) == -0.69)
        for x in stride(from: Float(0.7), through: 8, by: 0.05) {
            #expect(SoundMath.limited(x) <= SoundMath.ceiling)
            #expect(SoundMath.limited(-x) >= -SoundMath.ceiling)
        }
        #expect(SoundMath.limited(0.9) > SoundMath.limited(0.8), "louder in stays louder out")
        #expect(SoundMath.limited(0.9) < 0.9)
    }

    @Test("a new setting in the shared state counts as a new generation only when it differs")
    func stateGenerations() {
        let state = SoundTapState()
        #expect(state.setting == .off)
        #expect(state.generation == 0)
        let speech = SoundSetting(presetID: "speech", gain: 1)
        state.set(speech)
        #expect(state.setting == speech)
        #expect(state.generation == 1)
        state.set(speech)
        #expect(state.generation == 1, "the same setting again is no new generation")
        state.set(SoundSetting(presetID: "speech", gain: 1.5))
        #expect(state.generation == 2)
    }

    @Test("chains are built per tap and per new setting, never for the same setting again")
    func chainsAreBuiltOffTheAudioThread() {
        let state = SoundTapState()
        let first = SoundSlot(sampleRate: 44100, channels: 2)
        let second = SoundSlot(sampleRate: 48000, channels: 1)
        state.register(first)
        state.register(second)
        #expect(state.builds == 2, "each tap gets its chain when it learns its format")
        #expect(first.load() != nil)
        let before = first.load()
        state.set(SoundSetting(presetID: "speech", gain: 1))
        #expect(state.builds == 4, "a new setting builds one chain for every tap")
        #expect(first.load() != before, "the tap's slot holds the new chain")
        state.set(SoundSetting(presetID: "speech", gain: 1))
        #expect(state.builds == 4, "the same setting builds nothing")
        state.unregister(first)
        state.set(SoundSetting(presetID: "louder", gain: 1))
        #expect(state.builds == 5, "a tap that left gets no chain")
        #expect(first.load() == nil)
        state.unregister(second)
    }

    @Test("a chain the audio thread still runs is not freed, however long ago it was handed over")
    func aUsedChainStays() throws {
        let state = SoundTapState()
        let slot = SoundSlot(sampleRate: 44100, channels: 2)
        state.register(slot, now: 0)
        // The audio thread runs the first chain, then the tap pauses.
        slot.noteUsing(try #require(slot.load()))
        state.set(SoundSetting(presetID: "speech", gain: 1), now: 1)
        state.set(SoundSetting(presetID: "louder", gain: 1), now: 3_000_000_001)
        #expect(state.retiredCount == 2, "the first chain is old but still named by the paused tap, so it stays")
        // The tap runs again and moves to the newest chain.
        slot.noteUsing(slot.load())
        state.set(SoundSetting(presetID: "oldRecordings", gain: 1), now: 6_000_000_002)
        #expect(state.retiredCount == 1, "old chains nobody runs are freed; the one just handed over waits")
        state.unregister(slot)
    }

    @Test("a chain takes over the filter memory of the one before when the shape fits")
    func chainContinues() {
        let before = SoundChain(setting: SoundSetting(presetID: "speech", gain: 1), sampleRate: 44100, channels: 2)
        for index in 0..<(2 * before.delaysPerChannel) { before.delays[index] = Float(index) }
        let after = SoundChain(setting: SoundSetting(presetID: "louder", gain: 1.2), sampleRate: 44100, channels: 2)
        after.continueFrom(before)
        #expect((0..<(2 * after.delaysPerChannel)).allSatisfy { after.delays[$0] == Float($0) })
        let mono = SoundChain(setting: .off, sampleRate: 44100, channels: 1)
        mono.continueFrom(before)
        #expect((0..<mono.delaysPerChannel).allSatisfy { mono.delays[$0] == 0 }, "another shape starts clean")
    }

    @Test("the book stays on the device")
    func bookStaysOnTheDevice() {
        #expect(UserChoiceCatalog.statics[AppStorageKeys.soundBook] == .device)
    }

    @Test("Fence: the audio mix is set in one place, and the player hangs the filter only through the reach rule", .needsTheSources)
    func oneDoor() throws {
        let files = ProjectFileIntegrityTests.sourceTexts()
        try #require(files.count > 100, "the fence read no source file")
        let setters = files.filter { $0.text.contains(".audioMix = ") }.map(\.name)
        #expect(setters == ["SoundTap.swift"], "the audio mix is set only by the sound tap: \(setters)")
        let sound = try #require(files.first { $0.name == "PlayerViewModel+Sound.swift" }?.text)
        #expect(sound.contains("guard SoundReach.shouldTry(isRadio: isRadio"), "the player asks the reach rule before it hangs a filter")
        let player = try #require(files.first { $0.name == "PlayerViewModel.swift" }?.text)
        #expect(player.contains("hangSound(on: item, isRadio: isRadio)"), "every queue item passes the sound door")
        #expect(player.contains("followSoundRoute(notingRoute: self.isPlaying)"), "a route change takes the new route's setting")
        #expect(player.contains("followSoundRoute(notingRoute: true, hangsQueued: false)"),
                "a queue about to be built new takes no filters on the old items")
        let tap = try #require(files.first { $0.name == "SoundTap.swift" }?.text)
        let start = try #require(tap.range(of: "process: { tap, numberFrames"))
        let end = try #require(tap.range(of: "var tap: MTAudioProcessingTap?", range: start.upperBound..<tap.endIndex))
        let perBuffer = String(tap[start.lowerBound..<end.lowerBound])
        // The shared state sits behind a lock, so the loop does not touch it at all.
        for forbidden in ["withLock", "Mutex", ".state", "SoundChain(", "allocate", "Array(", "[Float]", ".set(", "register("] {
            #expect(!perBuffer.contains(forbidden), "the audio thread's buffer loop holds \(forbidden)")
        }
        #expect(perBuffer.contains("let raw = slot.load()"), "the buffer loop reads its chain without a lock")
        #expect(perBuffer.contains("slot.noteUsing(raw)"), "the buffer loop names the chain it runs")
        #expect(tap.contains("address.load(ordering: .acquiring)"), "the slot's read is atomic")
    }
}
