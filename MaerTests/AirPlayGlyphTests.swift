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
/// tap. It keeps no colour of its own for a route in use: the device's
/// picture showed the accent of an active route on dark glass.
struct AirPlayGlyphTests {
    @Test("Fence: the mini player draws the AirPlay mark in its own foreground and lets the picker take the tap unseen", .needsTheSources)
    func miniBarDrawsIt() throws {
        let bar = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/MiniPlayerBar.swift"), encoding: .utf8))
        let button = bar.components(separatedBy: "private var airPlayButton: some View {").dropFirst().first?
            .components(separatedBy: "private var playButton").first ?? ""
        #expect(button.contains("Image(systemName: \"airplay.audio\")"))
        // No colour of its own for a route in use: the device's picture
        // showed the accent of an active route, nearly lost on dark glass.
        #expect(button.contains(".foregroundStyle(.primary)"))
        #expect(!button.contains("AppTheme.accent") && !button.contains("routeActive"), "the mark keeps a colour of its own for a route in use")
        #expect(button.contains("AirPlayButton(tintColor: .clear)"), "the picker still draws the mark in its own colour")
        #expect(!button.contains("tintColor: .label"))
    }
}
#endif
