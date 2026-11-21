// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The full player's second row: four buttons, every other tool in "…",
/// the part line opens the parts, and the skip interval is a setting.
struct PlayerRowTests {
    static func read(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("the row holds speed (the queue and repeat for music), the sleep timer, the sound and the menu, and no skip interval",
          .needsTheSources)
    func fourButtons() throws {
        let player = try Self.read("Sources/Views/PlayerView.swift")
        let row = try #require(functionBody(of: "private var secondaryControls: some View {", in: player))
        for part in ["queueControl", "SpeedMenu(viewModel: viewModel, valueOnly: toolsAsSymbols)",
                     "SleepTimerMenu(viewModel: viewModel, columnCell: toolsAsSymbols, onPlayer: true)",
                     "EffectsButton(viewModel: viewModel, iconOnly: toolsAsSymbols)", "moreMenu",
                     "RepeatButton(iconOnly: toolsAsSymbols)"] {
            #expect(row.contains(part), "the row lacks \(part)")
        }
        // Speed and queue are two branches, never both; repeat stands only
        // for music: six shares in the code, four on screen for spoken
        // word, five for music.
        #expect(row.components(separatedBy: ".frame(maxWidth: .infinity)").count - 1 == 6, "the buttons do not share the width")
        for gone in ["setSkipInterval", "PlaybackSkip.options", "skipIntervalMenu", "symbolRow"] {
            #expect(!player.contains(gone), "the player still offers the skip interval or the old row: \(gone)")
        }
        #expect(player.contains("private var toolsAsSymbols: Bool { horizontalSizeClass == .compact }"))
    }

    @Test("every tool that left the rows is a line of the menu: parts, queue, bookmarks, playlist, mark as heard and the rest",
          .needsTheSources)
    func theMenuHoldsTheTools() throws {
        let player = try Self.read("Sources/Views/PlayerView.swift")
        let menu = try #require(functionBody(of: "private var moreMenu: some View {", in: player))
        #expect(menu.contains("if hasChapterEntry {") && menu.contains("showChapters = true") && menu.contains("moreTools"))
        #expect(menu.contains("Label(\"More\", systemImage: \"ellipsis.circle\")"), "the menu has no name for VoiceOver")
        let more = try #require(functionBody(of: "private var moreTools: some View {", in: player))
        #expect(more.contains("if !viewModel.isMusicItem && tools.contains(.queue) { queueControl }") && more.contains("restOfTools"),
                "the queue is lost for spoken word or doubled for music")
        let rest = try #require(functionBody(of: "private var restOfTools: some View {", in: player))
        for tool in ["bookmarksControl", "lyricsControl", "transcriptControl", "driveModeControl",
                     "markFinishedControl", "playlistControl"] {
            #expect(rest.contains(tool), "\(tool) is reachable nowhere")
        }
        // The side column keeps every tool as before.
        let glyphs = try #require(functionBody(of: "private var glyphTools: some View {", in: player))
        #expect(glyphs.contains("queueControl") && glyphs.contains("restOfTools"))
    }

    @Test("the line that names the part opens the parts, and at the accessibility sizes the time line keeps only the time left",
          .needsTheSources)
    func theHeader() throws {
        let player = try Self.read("Sources/Views/PlayerView.swift")
        let header = try #require(functionBody(of: "private var chapterHeader: some View {", in: player))
        #expect(header.contains("if viewModel.chaptersAreFallback && hasChapterEntry {\n                    partsLine {"),
                "a fallback book's part line does not open the parts")
        #expect(header.contains("partsLine {\n                    Text(chapterCounterText)"), "the chapter counter does not open the chapters")
        #expect(header.contains("(shortLine ? Text(verbatim: left) : whole)") && header.contains(".accessibilityLabel(whole)"),
                "at the accessibility sizes the line keeps more than the time left, or VoiceOver hears less")
        let line = try #require(functionBody(of: "private func partsLine<Content: View>(", in: player))
        #expect(line.contains("Button { showChapters = true }"))
    }

    @Test("both skip widths are set in Settings, each kept under its own key", .needsTheSources)
    func theSkipIsASetting() throws {
        let settings = try Self.read("Sources/Views/SettingsView.swift")
        #expect(settings.contains("AppStorageKeys.skipIntervalValue = newValue")
                && settings.contains("AppStorageKeys.musicSkipIntervalValue = newValue"),
                "a width has no setting, or writes another key")
        #expect(settings.contains("ForEach(PlaybackSkip.options(for: .music)"))
    }
}
#endif
