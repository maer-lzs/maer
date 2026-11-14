// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The half that can be decided without a screen: a
/// playlist without a single title offered shuffle playback, at the
/// corner of the card and in the context menu. A tap on it shuffled nothing and
/// said nothing; the component was there, the action could not act,
/// and „hat nicht funktioniert" could not be told from „hat nichts getan"
/// apart.
struct PlaylistEmptyCardTests {
    @Test("An empty list offers no shuffle playback")
    func anEmptyListOffersNoShuffle() {
        #expect(!PlaylistPresentation.offersShuffle(trackCount: 0))
        // The opposite case, so the rule does not simply forbid everything:
        // even a single title can be shuffled (the result is
        // the same title, but the action ACTS).
        #expect(PlaylistPresentation.offersShuffle(trackCount: 1))
        #expect(PlaylistPresentation.offersShuffle(trackCount: 42))
    }

    @Test("The card renders the rule instead of inventing a second one", .needsTheSources)
    func theCardRendersTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(
            contentsOf: root.appendingPathComponent("Sources/Views/Music/PlaylistCard.swift"),
            encoding: .utf8)
        let code = card.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // Both shuffle paths hang on the same gate: the corner of the card and
        // the entry in the context menu. Two gates would be two truths.
        #expect(code.contains("PlaylistPresentation.offersShuffle(trackCount:"))
        #expect(code.components(separatedBy: "if offersShuffle {").count - 1 == 1,
                "die Ecke haengt nicht am Tor")
        #expect(code.components(separatedBy: "isPlayable: offersShuffle,").count - 1 == 1,
                "das Menue (Abspielen, Als Naechstes, Zufaellig) haengt nicht am selben Tor wie die Ecke")
        // The way IN remains: an empty list is no dead end.
        #expect(code.contains("CardDetailPill(value: source.detailRoute)"))
    }
}
#endif
