// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The mini player always stands. Without a loaded title it shows the first
/// order waiting in Up Next, else the title heard last, else that nothing
/// waits; a tap opens Up Next. And the gain's line says it gives way where
/// a strong preset lifts the sound.
@MainActor
struct AlwaysMiniBarTests {
    @Test("without a session the bar shows the first order waiting, else the title heard last, else nothing waiting")
    func whatTheBarShows() {
        #expect(MiniBarFill.of(hasSession: true, waiting: ["a"], lastPlayed: "b") == .session)
        #expect(MiniBarFill.of(hasSession: false, waiting: ["a", "c"], lastPlayed: "b") == .waiting("a"))
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: "b") == .lastPlayed("b"))
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: nil) == .empty)
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: "") == .empty)
    }

    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Fence: the bar stands without a session, opens Up Next, and the space under the pages counts it always", .needsTheSources)
    func theBarAlwaysStands() throws {
        let library = try Self.code("Sources/Views/LibraryView.swift")
        #expect(library.contains("IdleMiniBar("), "without a session no bar stands")
        #expect(library.contains("onOpenQueue: { showQueueSheet = true }"))
        #expect(library.contains("BottomBarReserve.total(hasMiniPlayer: true,"), "the space under the pages leaves the bar out")
    }

    @Test("the line under the gain says it gives way under a strong preset, in English and German", .needsTheSources)
    func theGainLineSaysItGivesWay() throws {
        let sound = try Self.code("Sources/Views/SoundViews.swift")
        let english = "Raises the volume by up to 6 dB, about two steps of the volume buttons, less with a strong sound preset. A limiter keeps loud passages from distorting."
        #expect(sound.contains("Text(\"\(english)\")"))
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings[english] as? [String: Any])
        let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String
                == "Hebt die Lautstärke um bis zu 6 dB an, etwa zwei Stufen der Lautstärketasten, bei starker Klangeinstellung weniger. Ein Begrenzer hält laute Stellen frei von Verzerrung.")
    }
}
#endif
