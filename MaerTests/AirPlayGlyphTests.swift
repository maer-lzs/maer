// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import AVFoundation
import Foundation
import Testing
@testable import Maer

/// The AirPlay mark of the mini player wears the bar's own foreground, as
/// the pause beside it does: SwiftUI draws it, so the glass under the bar
/// adapts it; the system's route picker lies over it unseen and takes the
/// tap. Its UIKit tint (`.label`) followed only the light or dark mode of
/// the system, and on glass gone dark in light mode stood nearly black.
struct AirPlayGlyphTests {
    @Test("an output away from the device is a route in use: AirPlay, Bluetooth, the car, a screen")
    func externalRoute() {
        #expect(!AudioRouteRule.isExternal([.builtInSpeaker]))
        #expect(!AudioRouteRule.isExternal([.builtInReceiver]))
        #expect(!AudioRouteRule.isExternal([.headphones]), "wired headphones are the device's own")
        #expect(AudioRouteRule.isExternal([.airPlay]))
        #expect(AudioRouteRule.isExternal([.bluetoothA2DP]))
        #expect(AudioRouteRule.isExternal([.bluetoothLE]))
        #expect(AudioRouteRule.isExternal([.carAudio]))
        #expect(AudioRouteRule.isExternal([.HDMI]))
        #expect(!AudioRouteRule.isExternal([]))
    }

    @Test("Fence: the mini player draws the AirPlay mark in its own foreground and lets the picker take the tap unseen", .needsTheSources)
    func miniBarDrawsIt() throws {
        let bar = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/MiniPlayerBar.swift"), encoding: .utf8))
        let button = bar.components(separatedBy: "private var airPlayButton: some View {").dropFirst().first?
            .components(separatedBy: "private var playButton").first ?? ""
        #expect(button.contains("Image(systemName: \"airplay.audio\")"))
        #expect(button.contains(".foregroundStyle(routeActive ? AppTheme.accent : .primary)"))
        #expect(button.contains("AirPlayButton(tintColor: .clear)"), "the picker still draws the mark in its own colour")
        #expect(!button.contains("tintColor: .label"))
    }
}
#endif
