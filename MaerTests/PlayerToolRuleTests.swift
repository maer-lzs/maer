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

    @Test("ein Hoerbuch vom Server zeigt Schlange, Lesezeichen, Fahrmodus, Gehoert, Playlist")
    func serverBook() {
        let tools = PlayerToolRule.tools(for: input(.spokenWord, bookmarks: true))
        #expect(tools == [.queue, .bookmarks, .driveMode, .markFinished, .playlist])
    }

    @Test("ein Katalog-Hoerbuch hat keine Lesezeichen, aber eine Quelle und die Gehoert-Marke")
    func catalogueBook() {
        let tools = PlayerToolRule.tools(for: input(.spokenWord, catalogue: true))
        #expect(tools == [.queue, .driveMode, .markFinished, .playlist, .source])
    }

    @Test("eine Folge mit Transkript zeigt es, ohne Lesezeichen")
    func episodeWithTranscript() {
        let tools = PlayerToolRule.tools(for: input(.spokenWord, transcript: true))
        #expect(tools == [.queue, .driveMode, .transcript, .markFinished, .playlist])
    }

    /// Der Entscheid: bei Musik faellt die Gehoert-Marke weg.
    @Test("Musik hat keine Gehoert-Marke, wohl aber Playlist und gefundenen Liedtext")
    func music() {
        let tools = PlayerToolRule.tools(for: input(.music, lyrics: true))
        #expect(!tools.contains(.markFinished))
        #expect(tools == [.queue, .driveMode, .lyrics, .playlist])
    }

    @Test("Katalog-Musik traegt die Quelle, sonst wie Musik")
    func catalogueMusic() {
        let tools = PlayerToolRule.tools(for: input(.music, catalogue: true))
        #expect(tools == [.queue, .driveMode, .playlist, .source])
    }

    /// Ein Stream ist nie gehoert und steht in keiner Playlist: nur die
    /// zwei Werkzeuge, die keinem Titel gehoeren.
    @Test("Radio zeigt nur Schlange und Fahrmodus")
    func radio() {
        #expect(PlayerToolRule.tools(for: input(.liveStream)) == [.queue, .driveMode])
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

    @Test("die Regel enthaelt keine Verneinung einer Art")
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
