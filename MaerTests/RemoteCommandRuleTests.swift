// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// AirPods-Doppeldruck bei Musik = naechster Song: bei Musik sind nur die
/// Titel-Befehle an, keine Spruenge um Sekunden; Buecher, Podcasts und
/// Katalog-Werke wie bisher; Radio nichts.
struct RemoteCommandRuleTests {
    @Test("Die Tabelle je Medienart")
    func theTable() {
        typealias E = RemoteCommandRule.Enabled
        #expect(RemoteCommandRule.enabled(for: .music) == E(skip: false, track: true))
        #expect(RemoteCommandRule.enabled(for: .book) == E(skip: true, track: true))
        #expect(RemoteCommandRule.enabled(for: .podcast) == E(skip: true, track: true))
        #expect(RemoteCommandRule.enabled(for: .catalog) == E(skip: true, track: true))
        #expect(RemoteCommandRule.enabled(for: .radio) == E(skip: false, track: false))
        #expect(RemoteCommandRule.enabled(for: .unknown) == E(skip: true, track: true))
        #expect(MediaFamily.allCases.count == 6, "a new family needs a row here")
    }

    @Test("Die Befehle folgen der Regel je Titel, und jeder eingehende Befehl schreibt eine Zeile", .needsTheSources)
    func theWiring() throws {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"),
            encoding: .utf8))
        let update = try #require(functionBody(of: "func updateNowPlayingInfo() {", in: source))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(update.contains("RemoteCommandRule.enabled(for:"))
        for command in ["skipForwardCommand.isEnabled=enabled.skip", "skipBackwardCommand.isEnabled=enabled.skip",
                        "nextTrackCommand.isEnabled=enabled.track", "previousTrackCommand.isEnabled=enabled.track"] {
            #expect(update.contains(command), "\(command)")
        }
        let flat = source.components(separatedBy: .whitespacesAndNewlines).joined()
        for name in ["noteRemoteCommand(\"skipForward\")", "noteRemoteCommand(\"skipBackward\")",
                     "noteRemoteCommand(forward?\"nextTrack\":\"previousTrack\")"] {
            #expect(flat.contains(name), "\(name)")
        }
    }
}
#endif
