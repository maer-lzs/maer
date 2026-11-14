// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
@testable import Maer

/// The sound surfaces: the player's sheet for the connected device, the
/// default and every device in the settings, one choice for all three.
struct SoundSurfaceTests {
    private static func route(_ type: String, _ uid: String, _ name: String) -> SoundRoute {
        SoundRoute(portType: type, uid: uid, name: name)
    }

    @Test("a car is named CarPlay with its name, every other device by the name the system gives")
    func theNameOfADevice() {
        #expect(SoundSurface.carPortType == AVAudioSession.Port.carAudio.rawValue, "the port type of CarPlay moved")
        #expect(SoundSurface.deviceName(Self.route(AVAudioSession.Port.carAudio.rawValue, "c1", "Golf")) == .car("Golf"))
        #expect(SoundSurface.deviceName(Self.route(AVAudioSession.Port.bluetoothA2DP.rawValue, "b1", "Phonak")) == .plain("Phonak"))
    }

    @Test("the summary of a setting as a table: none follows the default, off, a preset, a raised gain")
    func theSummaryAsATable() {
        #expect(SoundSurface.summary(nil) == .followsDefault)
        #expect(SoundSurface.summary(.off) == .off)
        #expect(SoundSurface.summary(SoundSetting(presetID: "speech", gain: 1)) == .preset(id: "speech", gainPercent: nil))
        #expect(SoundSurface.summary(SoundSetting(presetID: "off", gain: 1.5)) == .preset(id: "off", gainPercent: 150))
        #expect(SoundSurface.summary(SoundSetting(presetID: "unknown", gain: 1)) == .off, "an unknown preset reads as off")
    }

    @Test("a station is always blocked, a title only once the filter found no audio track or could not read them")
    func whereTheFilterCannotWork() {
        #expect(SoundSurface.block(isRadio: true, lastAttach: nil) == .station)
        #expect(SoundSurface.block(isRadio: false, lastAttach: nil) == nil)
        #expect(SoundSurface.block(isRadio: false, lastAttach: .hung) == nil)
        #expect(SoundSurface.block(isRadio: false, lastAttach: .noAudioTrack) == .convertedStream)
        #expect(SoundSurface.block(isRadio: false, lastAttach: .tracksNotRead(reason: "x")) == .convertedStream)
        #expect(SoundSurface.block(isRadio: false, lastAttach: .alreadyHung) == nil)
    }

    @Test("the gain runs from 100 to 200 percent, held at both ends")
    func theGainSteps() {
        #expect(SoundSurface.gainPercent(1) == 100)
        #expect(SoundSurface.gainPercent(1.5) == 150)
        #expect(SoundSurface.gainPercent(3) == 200)
        #expect(SoundSurface.gainPercent(.nan) == 100)
        #expect(SoundSurface.gain(percent: 50) == 1)
        #expect(SoundSurface.gain(percent: 175) == 1.75)
        #expect(SoundSurface.gain(percent: 173.4) == 1.75, "a position between two steps takes the nearer")
        #expect(SoundSurface.gain(percent: 400) == SoundSetting.gainLimit)
        #expect(SoundSurface.gain(percent: .nan) == 1)
    }

    @Test("the player's choice goes to the connected device, or to the default without a route; a device's page sets or clears its own")
    func theEditsOfTheBook() {
        let car = Self.route("CarAudio", "c1", "Golf")
        let speech = SoundSetting(presetID: "speech", gain: 1.2)
        let byPlayer = SoundBookEdit.choosing(speech, for: car, in: SoundBook())
        #expect(byPlayer.setting(for: car) == speech)
        #expect(byPlayer.fallback == .off, "the player's choice for a device moved the default")
        let noRoute = SoundBookEdit.choosing(speech, for: nil, in: SoundBook())
        #expect(noRoute.fallback == speech && noRoute.devices.isEmpty)
        let cleared = SoundBookEdit.choosing(nil, forDevice: car.key, in: byPlayer)
        #expect(cleared.devices.count == 1 && cleared.setting(for: car) == .off, "a cleared device does not follow the default")
        let louder = SoundBookEdit.defaulting(SoundSetting(presetID: "louder", gain: 1), in: cleared)
        #expect(louder.setting(for: car).presetID == "louder", "a device without its own setting does not follow the default")
        #expect(SoundBookEdit.choosing(speech, forDevice: "unknown", in: SoundBook()) == SoundBook(),
                "a page of a device no longer in the book added it")
    }

    @Test("the sheet, the default and a device's page draw the one choice and write through the one edit", .needsTheSources)
    func oneChoiceForThreePlaces() throws {
        let views = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Views/SoundViews.swift"), encoding: .utf8))
        #expect(views.components(separatedBy: "SoundChoiceSections(setting:").count - 1 == 3, "a place draws its own choice")
        for head in ["struct EffectsSheet: View {", "struct SoundDefaultView: View {", "struct SoundDeviceView: View {"] {
            let body = try #require(functionBody(of: head, in: views), "\(head) was not found")
            #expect(body.contains("SoundChoiceSections(setting:"), "\(head) does not draw the one choice")
        }
        #expect(views.components(separatedBy: "soundBookValue = ").count - 1 == 1, "a view writes the book past the one write")
        let write = try #require(functionBody(of: "static func save(_ book: SoundBook, into binding: Binding<SoundBook>, coordinator: PlayerCoordinator) {", in: views))
        #expect(write.contains("AppStorageKeys.soundBookValue = book")
                && write.contains("coordinator.viewModel?.followSoundRoute(notingRoute: false)"),
                "the settings keep the book without the player taking it at once")
        let sound = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel+Sound.swift"), encoding: .utf8))
        #expect(sound.contains("SoundBookEdit.choosing(setting, for: soundRoute, in: book)"))
        let player = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/Views/PlayerView.swift"), encoding: .utf8))
        let speed = try #require(functionBody(of: "private var speedControl: some View {", in: player))
        #expect(speed.contains("SpeedMenu(viewModel: viewModel)") && speed.contains("EffectsButton(viewModel: viewModel)"),
                "the effects do not stand beside the speed")
    }
}
#endif
