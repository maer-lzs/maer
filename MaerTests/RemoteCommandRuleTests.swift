// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// AirPods-Doppeldruck bei Songs = naechster Song: bei Songs sind nur die
/// Titel-Befehle an, keine Spruenge um Sekunden. Ein Song aus einem freien
/// Katalog ist ein Song, ein Katalog-Hoerbuch nicht (Entscheid 28.09.2026).
/// „Zurueck“ in den ersten Sekunden geht zum Song davor, auch ueber die
/// Grenze eines Eintrags; Buecher, Podcasts und Hoerbuecher wie bisher; Radio
/// nichts.
struct RemoteCommandRuleTests {
    @Test("Die Tabelle je Titel: Katalog-Song, Katalog-Hoerbuch, Musik, Buch, Podcast, Radio")
    func theTable() {
        typealias E = RemoteCommandRule.Enabled
        let songs = E(skip: false, track: true), spoken = E(skip: true, track: true)
        let table: [(String?, RemoteCommandRule.Kind, E)] = [
            ("jam:12345", .songs, songs),                  // Jamendo, Musik der Art nach
            ("lva:some_item#3", .songs, songs),            // ein Song aus archive.org
            ("lv:1234", .spoken, spoken),                  // LibriVox-Hoerbuch
            ("gut:5884", .spoken, spoken),                 // Gutenberg-Hoerbuch
            ("sub:song:9", .songs, songs),                 // Musik vom Server
            ("local:book-1", .spoken, spoken),             // Hoerbuch
            ("rss:feed:ep-1", .spoken, spoken),            // Podcast
            ("radio:station-1", .live, E(skip: false, track: false)),
            (nil, .spoken, spoken),                        // nichts geladen
        ]
        for (id, kind, enabled) in table {
            #expect(RemoteCommandRule.kind(forItem: id) == kind, "\(id ?? "nil")")
            #expect(RemoteCommandRule.enabled(for: kind) == enabled, "\(id ?? "nil")")
        }
        #expect(MediaFamily.allCases.count == 6, "a new family needs a row here")
    }

    @Test("Zurueck: 1 s geht zum Song davor, 5 s an den Anfang; erster Song mit Vorgaenger geht zum Vorgaenger, der allererste an den Anfang")
    func theBackRule() {
        typealias B = RemoteCommandRule.Back
        #expect(RemoteCommandRule.back(withinTrack: 5, trackIndex: 2, hasSongBefore: true) == B.startOfTrack)
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 2, hasSongBefore: false) == B.previousTrack)
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 0, hasSongBefore: true) == B.songBefore,
                "erster Song im Album, davor lief ein anderer: ueber die Grenze zurueck")
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 0, hasSongBefore: false) == B.startOfItem,
                "der allererste Song: an den Anfang")
        #expect(RemoteCommandRule.back(withinTrack: 5, trackIndex: 0, hasSongBefore: true) == B.startOfTrack)
        #expect(RemoteCommandRule.back(withinTrack: 3, trackIndex: 0, hasSongBefore: true) == B.songBefore,
                "genau drei Sekunden zaehlen noch als Anfang")
    }

    @Test("Gemerkt wird nur ein Song, der einem anderen Titel weicht")
    func whatIsRemembered() {
        #expect(RemoteCommandRule.remembersForBack(leaving: "sub:song:1", starting: "sub:song:2"))
        #expect(RemoteCommandRule.remembersForBack(leaving: "jam:1", starting: "sub:song:2"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: "rss:feed:ep-1", starting: "sub:song:2"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: "sub:song:1", starting: "sub:song:1"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: nil, starting: "sub:song:1"))
    }

    @Test("Der Rueckweg haengt an der Regel und am Stapel der Sitzung", .needsTheSources)
    func theBackWiring() throws {
        let player = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(player.contains("switchRemoteCommandRule.back(withinTrack:"))
        #expect(player.contains("hasSongBefore:hasSongBefore?()??false"))
        let coordinator = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(coordinator.contains("RemoteCommandRule.remembersForBack(leaving:activeItem?.id,starting:item.id)"))
        #expect(coordinator.contains("self.songsBefore.popLast()"))
        #expect(coordinator.contains("open(item:previous,restart:true,preservesContext:true)"))
        let press = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"), encoding: .utf8))
        #expect(press.contains("switch RemoteCommandRule.kind(forItem: id)"), "die Taste fragt dieselbe Regel wie der Sperrbildschirm")
    }

    @Test("Die drei Arten und ihre Befehle")
    func theKinds() {
        typealias E = RemoteCommandRule.Enabled
        #expect(RemoteCommandRule.enabled(for: .songs) == E(skip: false, track: true))
        #expect(RemoteCommandRule.enabled(for: .spoken) == E(skip: true, track: true))
        #expect(RemoteCommandRule.enabled(for: .live) == E(skip: false, track: false))
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
