// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One case per kind on the RULE, not on the surface. And a probe on the
/// form: the assignment is positive, nothing in it is written as "not
/// music".
struct PlayerToolRuleTests {
    private func input(_ content: PlayerToolRule.Content, bookmarks: Bool = false,
                       lyrics: Bool = false, transcript: Bool = false,
                       catalogue: Bool = false) -> PlayerToolRule.Input {
        .init(content: content, providerKeepsBookmarks: bookmarks,
              hasLyrics: lyrics, hasTranscript: transcript, isCatalogue: catalogue)
    }

    /// The rule with drive mode's gate open, the form these cases describe.
    private func open(_ input: PlayerToolRule.Input) -> Set<PlayerToolRule.Tool> {
        PlayerToolRule.tools(for: input, driveModeOpen: true)
    }

    @Test("bei geschlossenem Tor gibt es den Fahrmodus in keiner Art, und das Tor ist zu")
    func driveModeClosed() {
        #expect(!DriveModeGate.isOpen)
        for content in [PlayerToolRule.Content.spokenWord, .music, .liveStream] {
            #expect(!PlayerToolRule.tools(for: input(content)).contains(.driveMode))
        }
    }

    @Test("kein Eingang erreicht den Fahrmodus: Knopf, Siri, Selbststart und Einstellungen fragen das Tor", .needsTheSources)
    func noEntryReachesDriveMode() throws {
        let read = { (path: String) in
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let controller = try read("Sources/Views/DriveMode.swift")
        #expect(controller.contains("func enter() {\n        guard DriveModeGate.isOpen else {"))
        let shortcuts = try read("Sources/AppShortcuts.swift")
        #expect(!shortcuts.contains("intent: DriveModeIntent()"), "Siri offers drive mode again")
        #expect(shortcuts.contains("static var isDiscoverable: Bool { DriveModeGate.isOpen }"))
        let settings = try read("Sources/Views/SettingsView.swift")
        #expect(settings.contains("if DriveModeGate.isOpen { driveModeSection }"))
        // The mode is entered only through `enter()`.
        var setters: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "DriveMode.swift" {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains("isActive = true") && text.contains("DriveMode") { setters.append(file.lastPathComponent) }
        }
        #expect(setters.isEmpty, "drive mode is switched on past its gate: \(setters)")
    }

    @Test("ein Hoerbuch vom Server zeigt Schlange, Lesezeichen, Fahrmodus, Gehoert, Playlist")
    func serverBook() {
        let tools = open(input(.spokenWord, bookmarks: true))
        #expect(tools == [.queue, .bookmarks, .driveMode, .markFinished, .playlist])
    }

    @Test("ein Katalog-Hoerbuch hat keine Lesezeichen, aber eine Quelle und die Gehoert-Marke")
    func catalogueBook() {
        let tools = open(input(.spokenWord, catalogue: true))
        #expect(tools == [.queue, .driveMode, .markFinished, .playlist, .source])
    }

    @Test("eine Folge mit Transkript zeigt es, ohne Lesezeichen")
    func episodeWithTranscript() {
        let tools = open(input(.spokenWord, transcript: true))
        #expect(tools == [.queue, .driveMode, .transcript, .markFinished, .playlist])
    }

    /// Der Entscheid: bei Musik faellt die Gehoert-Marke weg.
    @Test("Musik hat keine Gehoert-Marke, wohl aber Playlist und gefundenen Liedtext")
    func music() {
        let tools = open(input(.music, lyrics: true))
        #expect(!tools.contains(.markFinished))
        #expect(tools == [.queue, .driveMode, .lyrics, .playlist])
    }

    @Test("Katalog-Musik traegt die Quelle, sonst wie Musik")
    func catalogueMusic() {
        let tools = open(input(.music, catalogue: true))
        #expect(tools == [.queue, .driveMode, .playlist, .source])
    }

    /// Ein Stream ist nie gehoert und steht in keiner Playlist: nur die
    /// zwei Werkzeuge, die keinem Titel gehoeren.
    @Test("Radio zeigt nur Schlange und Fahrmodus")
    func radio() {
        #expect(open(input(.liveStream)) == [.queue, .driveMode])
    }

    /// Rot-Probe auf die FORM: die Regel ordnet positiv zu. Eine
    /// Verneinung wie „nicht Musik" wuerde jeder kuenftigen Familie alles
    /// vererben.
    /// Der Pruefer als pure Funktion ueber den Quelltext: Kommentarzeilen
    /// fallen weg, dann werden die verneinten Art-Formen gezaehlt.
    private static func negatedKindForms(in text: String) -> [String] {
        let code = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        return ["!= .music", "!isMusic", "!= .liveStream", "!= .spokenWord"].filter { code.contains($0) }
    }

    @Test("die Regel enthaelt keine Verneinung einer Art", .needsTheSources)
    func ruleIsWrittenPositively() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Models/PlayerToolRule.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(Self.negatedKindForms(in: text).isEmpty)
        // Rot-Proben am PRUEFER: die Form im Code faellt auf, dieselbe
        // Form in einem Kommentar nicht.
        #expect(Self.negatedKindForms(in: "if kind != .music { x }") == ["!= .music"])
        #expect(Self.negatedKindForms(in: "// if kind != .music { x }").isEmpty)
    }
}
#endif
