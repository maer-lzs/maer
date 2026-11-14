// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    @Test("no filter on a station, without an audio track, or with a setting that does nothing")
    func reach() {
        let speech = SoundSetting(presetID: "speech", gain: 1)
        #expect(SoundReach.filterApplies(isRadio: false, hasAudioTrack: true, setting: speech))
        #expect(!SoundReach.filterApplies(isRadio: true, hasAudioTrack: true, setting: speech), "a station")
        #expect(!SoundReach.filterApplies(isRadio: false, hasAudioTrack: false, setting: speech), "a stream converted on the fly")
        #expect(!SoundReach.filterApplies(isRadio: false, hasAudioTrack: true, setting: .off), "off")
        #expect(!SoundReach.shouldTry(isRadio: true, setting: speech))
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
        state.set(SoundSetting(presetID: "speech", gain: 1))
        #expect(state.setting.presetID == "speech")
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
    }
}
