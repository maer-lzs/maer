// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Visible things already decided: a list with nothing to play is no
/// error, the page of all lists keeps its name, an unread sign-in is named
/// as such, the mini player's second line is readable on glass, the offer
/// after a rule "next" sets the show in order, and the band of the widget
/// grows at an accessibility size.
@MainActor
struct VisibleDecidedTests {
    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("a list with nothing to play right now says so with the info sign; a list not on this device keeps the warning", .needsTheSources)
    @available(iOS 27, *)
    func nothingToPlayIsNoError() throws {
        let list = MaerPlaylists.Playlist(id: "l", name: "L", updatedAt: 1, itemIds: [])
        #expect(PlaylistStart.cause(for: .start(list), started: false) == .nothingYet)
        #expect(PlaylistStart.cause(for: .missing, started: false) == .unknown)
        #expect(PlaylistStart.cause(for: .wait, started: false) == .unknown)
        let shortcuts = try Self.code("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("say(sentence, cause(for: request, started: started))"), "the sentence goes without its sign")
    }

    @Test("Fence: the page of all lists keeps its name when its last list goes", .needsTheSources)
    func thePageKeepsItsName() throws {
        let page = try Self.code("Sources/Views/Music/PlaylistNameList.swift")
        #expect(page.contains("content.navigationTitle(title)"), "the name hangs on a list that can go")
    }

    @Test("an unread sign-in at the start is named as such, never with the placeholder host")
    func anUnreadSignInIsNamed() {
        var facts = SourceMapFacts()
        facts.absConnected = true
        facts.absServer = "https://example.invalid"
        facts.absAccessUnread = true
        #expect(facts.state(of: .audiobooks) == .accessUnread)
        facts.absAccessUnread = false
        facts.absServer = "https://books.example.org"
        #expect(facts.state(of: .audiobooks) == .connected(host: "books.example.org"))
    }

    @Test("the line of an unread sign-in has its words, in English and German", .needsTheSources)
    func theUnreadLineHasItsWords() throws {
        let card = try Self.code("Sources/Views/SourceMapCard.swift")
        #expect(card.contains("Text(\"Sign-in will be read once the iPhone is unlocked\")"))
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings["Sign-in will be read once the iPhone is unlocked"] as? [String: Any])
        let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == "Anmeldung wird gelesen, sobald das iPhone entsperrt ist")
    }

    @Test("Fence: the mini player's second line stands in the main colour at 82 percent, every form of it", .needsTheSources)
    func theSecondLineIsReadable() throws {
        let bar = try Self.code("Sources/Views/MiniPlayerBar.swift")
        #expect(bar.contains("static let secondLine = Color.primary.opacity(0.82)"))
        #expect(bar.components(separatedBy: ".foregroundStyle(Self.secondLine)").count - 1 == 5, "a form of the second line stays grey")
        #expect(bar.components(separatedBy: ".foregroundStyle(.secondary)").count - 1 == 1, "only the placeholder's sign stays grey")
    }

    @Test("the offer after a rule next sets the show in order; after newest it leaves the direction", .needsTheSources)
    func theOfferAfterNextIsInOrder() throws {
        #expect(RoutinePlayback.offerDirection(for: ["rule:next:2:abc"]) == .inOrder)
        #expect(RoutinePlayback.offerDirection(for: ["rule:newest:abc"]) == nil)
        #expect(RoutinePlayback.offerDirection(for: ["rss:abc:1"]) == nil)
        let sheet = try Self.code("Sources/Views/Music/AddToPlaylistSheet.swift")
        #expect(sheet.contains("if let direction = presenter.offeringDirection { PodcastAutoDownload.setDirection(show.id, direction) }"),
                "the offer does not set the direction")
    }

    @Test("at an accessibility size the band of the widget grows and its title takes two lines", .needsTheSources)
    func theBandGrows() throws {
        #expect(WidgetRows.bandCoverFraction(accessibilitySize: false) == 0.75)
        #expect(WidgetRows.bandCoverFraction(accessibilitySize: true) == 0.6)
        #expect(WidgetRows.bandTitleLines(accessibilitySize: false) == 1)
        #expect(WidgetRows.bandTitleLines(accessibilitySize: true) == 2)
        let widget = try Self.code("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("WidgetRows.bandCoverFraction(accessibilitySize: dynamicTypeSize.isAccessibilitySize)"))
        #expect(widget.contains("WidgetRows.bandTitleLines(accessibilitySize: dynamicTypeSize.isAccessibilitySize)"))
    }
}
#endif
