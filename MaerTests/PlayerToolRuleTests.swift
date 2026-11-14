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

    @Test("with the gate closed, drive mode exists in no kind, and the gate is shut")
    func driveModeClosed() {
        #expect(!DriveModeGate.isOpen)
        for content in [PlayerToolRule.Content.spokenWord, .music, .liveStream] {
            #expect(!PlayerToolRule.tools(for: input(content)).contains(.driveMode))
        }
    }

    @Test("no entry reaches drive mode: button, Siri, self-start and settings ask the gate", .needsTheSources)
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

    @Test("an audiobook from the server shows queue, bookmarks, drive mode, heard, playlist")
    func serverBook() {
        let tools = open(input(.spokenWord, bookmarks: true))
        #expect(tools == [.queue, .bookmarks, .driveMode, .markFinished, .playlist])
    }

    @Test("a catalog audiobook has no bookmarks, but a source and the heard mark")
    func catalogueBook() {
        let tools = open(input(.spokenWord, catalogue: true))
        #expect(tools == [.queue, .driveMode, .markFinished, .playlist, .source])
    }

    @Test("an episode with a transcript shows it, without bookmarks")
    func episodeWithTranscript() {
        let tools = open(input(.spokenWord, transcript: true))
        #expect(tools == [.queue, .driveMode, .transcript, .markFinished, .playlist])
    }

    /// The decision: for music the heard mark is dropped.
    @Test("Music has no heard mark, but a playlist and found lyrics")
    func music() {
        let tools = open(input(.music, lyrics: true))
        #expect(!tools.contains(.markFinished))
        #expect(tools == [.queue, .driveMode, .lyrics, .playlist])
    }

    @Test("Catalog music carries the source, otherwise like music")
    func catalogueMusic() {
        let tools = open(input(.music, catalogue: true))
        #expect(tools == [.queue, .driveMode, .playlist, .source])
    }

    /// A stream is never heard and is in no playlist: only the
    /// two tools that belong to no title.
    @Test("Radio shows only queue and drive mode")
    func radio() {
        #expect(open(input(.liveStream)) == [.queue, .driveMode])
    }

    /// Red probe on the FORM: the rule assigns positively. A
    /// negation like „nicht Musik" would pass everything on to every
    /// future family.
    /// The checker as a pure function over the source text: comment lines
    /// are dropped, then the negated kind forms are counted.
    private static func negatedKindForms(in text: String) -> [String] {
        let code = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        return ["!= .music", "!isMusic", "!= .liveStream", "!= .spokenWord"].filter { code.contains($0) }
    }

    @Test("the rule contains no negation of a kind", .needsTheSources)
    func ruleIsWrittenPositively() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Models/PlayerToolRule.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(Self.negatedKindForms(in: text).isEmpty)
        // Red probes on the CHECKER: the form in code is caught, the same
        // form in a comment is not.
        #expect(Self.negatedKindForms(in: "if kind != .music { x }") == ["!= .music"])
        #expect(Self.negatedKindForms(in: "// if kind != .music { x }").isEmpty)
    }
}
#endif
