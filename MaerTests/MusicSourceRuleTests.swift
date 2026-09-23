// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One rule answers which music server serves the device and which serves
/// one item. With one active music source the two answers are the same, so
/// sending a single-item question to the door changes nothing there; only
/// with two does the item's own server win.
struct MusicSourceRuleTests {
    static let ids = ["jf:album:1", "jf:artist:2", "jf:song:3", "sub:album:1", "sub:artist:2",
                      "sub:song:3", "maer-playlist-42", ""]

    @Test("mit EINER aktiven Musikquelle antwortet die Tuer je Eintrag dieselbe Quelle wie das Geraet")
    func withOneSourceTheDoorAnswersTheDevice() {
        for (subsonic, jellyfin) in [(true, false), (false, true)] {
            let device = MusicSourceRule.device(subsonicServesMusic: subsonic, jellyfinServesMusic: jellyfin)
            // With one server set up, every item it hands out carries its own
            // namespace, or none at all.
            let own = device == .jellyfin ? "jf:" : "sub:"
            for id in Self.ids where id.hasPrefix(own) || !(id.hasPrefix("jf:") || id.hasPrefix("sub:")) {
                #expect(MusicSourceRule.item(id, device: device) == device, "\(id) bei \(device)")
            }
        }
        #expect(MusicSourceRule.device(subsonicServesMusic: false, jellyfinServesMusic: false) == .subsonic,
                "ohne Musikquelle wie bisher")
    }

    @Test("mit ZWEI Quellen gewinnt fuer einen Eintrag sein eigener Server")
    func withTwoSourcesTheItemsServerWins() {
        let device = MusicSourceRule.device(subsonicServesMusic: true, jellyfinServesMusic: true)
        #expect(device == .subsonic, "das Geraet: vorerst Subsonic, die Frage von F5b")
        #expect(MusicSourceRule.item("jf:artist:2", device: device) == .jellyfin)
        #expect(MusicSourceRule.item("sub:artist:2", device: device) == .subsonic)
        #expect(MusicSourceRule.item("maer-playlist-42", device: device) == .subsonic,
                "ohne Namensraum antwortet das Geraet")
    }

    /// The search target keeps the hit's item id, so the page that opens it
    /// resolves the artist at the hit's own server.
    @Test("ein Kuenstler-Treffer traegt seine Kennung bis zum Ziel")
    func anArtistHitCarriesItsIdToTheTarget() {
        let hit = SearchResult(id: "jf:artist:9", kind: .artist, title: "A", subtitle: nil, coverURL: nil)
        var asked: [String] = []
        let lookups = SearchLookups(item: { _ in false }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in false },
                                    artistId: { $0.hasPrefix("jf:artist:") ? "9" : nil },
                                    artistKnown: { asked.append($0); return true })
        #expect(SearchRouting.target(for: hit, lookups: lookups) == .artist(itemId: "jf:artist:9"))
        #expect(asked == ["jf:artist:9"], "gefragt wird mit der Kennung des Treffers, nicht mit der rohen Nummer")
        let unknown = SearchLookups(item: { _ in false }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in false }, artistId: { _ in "9" },
                                    artistKnown: { _ in false })
        #expect(SearchRouting.target(for: hit, lookups: unknown) == .unavailable)
    }

    /// The single-item questions of F5a ask the door, whoever the receiver.
    @Test("Spieler-Kuenstler und Such-Ziel fragen die Tuer je Eintrag", .needsTheSources)
    func thePlayerAndTheSearchTargetAskTheDoor() throws {
        func code(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let player = try code("Sources/Views/PlayerView.swift")
        #expect(player.contains("AppSession.shared.musicProvider(for: id).allArtists()"))
        let door = try #require(functionBody(of: "static func target(for result: SearchResult) -> SearchTarget {",
                                             in: try code("Sources/ViewModels/SearchDoor.swift")))
        #expect(MusicProviderDoorFenceTests.deviceQuestions(in: door) == 0,
                "das Such-Ziel fragt wieder das Geraet")
        let library = try #require(functionBody(of: "private func openSearchResult(_ result: SearchResult) {",
                                                in: try code("Sources/Views/LibraryView.swift")))
        #expect(MusicProviderDoorFenceTests.deviceQuestions(in: library) == 0,
                "die Treffer-Seite fragt wieder das Geraet")
    }
}
#endif
