// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// M3: pure genre presentation (filter empties, count-desc sort, alphabetical
/// without counts) and the curated glyph mapping with its deterministic
/// fallback.
struct MusicGenreTests {

    @Test("Empty names and KNOWN-empty genres drop; unknown counts (Jellyfin) stay")
    func presentationFilter() {
        let out = MusicGenrePresentation.presented([
            MusicGenre(name: "  ", songCount: 9, albumCount: 9),
            MusicGenre(name: "Empty", songCount: 0, albumCount: 0),
            MusicGenre(name: "Unknown"),                      // nil counts → keep
            MusicGenre(name: "Rock", songCount: 5, albumCount: 2),
        ])
        #expect(out.map(\.name) == ["Rock", "Unknown"])
    }

    @Test("Sort: album count desc, then song count, then name — count-less lists end up alphabetical")
    func presentationSort() {
        let out = MusicGenrePresentation.presented([
            MusicGenre(name: "B", songCount: 10, albumCount: 3),
            MusicGenre(name: "A", songCount: 99, albumCount: 3),
            MusicGenre(name: "C", songCount: 1, albumCount: 7),
        ])
        #expect(out.map(\.name) == ["C", "A", "B"])
        let alpha = MusicGenrePresentation.presented([
            MusicGenre(name: "Zeta"), MusicGenre(name: "alpha"), MusicGenre(name: "Beta"),
        ])
        #expect(alpha.map(\.name) == ["alpha", "Beta", "Zeta"])
    }

    @Test("Glyphs: curated exact hits incl. normalization (case, diacritics, separators)")
    func glyphExact() {
        #expect(MusicGenreGlyphs.symbol(for: "Rock") == "guitars")
        #expect(MusicGenreGlyphs.symbol(for: "Hip-Hop") == "headphones")
        #expect(MusicGenreGlyphs.symbol(for: "ELECTRONIC") == "waveform")
        #expect(MusicGenreGlyphs.symbol(for: "Hörspiel") == "book")
        #expect(MusicGenreGlyphs.symbol(for: "Klassik") == "pianokeys")
    }

    @Test("Glyphs: whole-word match for compounds; unknown → deterministic music.note")
    func glyphFallback() {
        #expect(MusicGenreGlyphs.symbol(for: "Progressive Rock") == "guitars")
        #expect(MusicGenreGlyphs.symbol(for: "Deutscher Jazz") == "music.quarternote.3")
        #expect(MusicGenreGlyphs.symbol(for: "Vaporwave Obscuro") == "music.note")
        #expect(MusicGenreGlyphs.symbol(for: "") == "music.note")
        // NEVER guess-and-wrong: a substring inside a word does not match
        // ("Kindergarten Punk" maps via the WORD punk, not via "kinder…").
        #expect(MusicGenreGlyphs.symbol(for: "Krautrock") == "music.note")
    }
}
#endif
