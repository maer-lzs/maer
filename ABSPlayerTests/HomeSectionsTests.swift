// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Etappe 3: Home ranks strictly by timestamp, merges sources, de-dups by id.
struct HomeSectionsTests {
    @Test("byRecency merges sources newest-first, de-duplicated, capped")
    func merge() {
        let books = [("b1", 30.0), ("b2", 10.0)]
        let episodes = [("e1", 20.0), ("b1", 40.0)]   // b1 also here, newer ts
        let r = HomeSections.byRecency([books, episodes], limit: 10)
        // b1 keeps its newest ts (40) → first; then e1 (20), b2 (10).
        #expect(r == ["b1", "e1", "b2"])
    }

    @Test("byRecency caps at the limit")
    func cap() {
        let src = (0..<20).map { (id: "i\($0)", ts: Double($0)) }
        #expect(HomeSections.byRecency([src], limit: 5).count == 5)
        #expect(HomeSections.byRecency([src], limit: 5).first == "i19")   // newest
    }

    @Test("byRecency on empty sources is empty")
    func empty() {
        #expect(HomeSections.byRecency([], limit: 5).isEmpty)
        #expect(HomeSections.byRecency([[]], limit: 5).isEmpty)
    }

    @Test("byRecency ranks a THIRD stream (music playlists) purely by recency")
    func threeStreams() {
        let books = [("b1", 30.0)]
        let episodes = [("e1", 15.0)]
        let music = [("sub:playlist:p1", 45.0), ("sub:playlist:p2", 5.0)]
        // Package 3: music is just another input to the same merge — pure recency.
        let r = HomeSections.byRecency([books, episodes, music], limit: 8)
        #expect(r == ["sub:playlist:p1", "b1", "e1", "sub:playlist:p2"])
    }

    // MARK: - X1a: fair interleave (both libraries stay present)

    @Test("interleave alternates sources so neither starves")
    func interleaveFair() {
        let books = ["b1", "b2"]
        let albums = ["a1", "a2", "a3", "a4"]
        // Round-robin: b1, a1, b2, a2, then albums continue alone.
        #expect(HomeSections.interleave([books, albums], limit: 10) == ["b1", "a1", "b2", "a2", "a3", "a4"])
    }

    @Test("interleave keeps a short source represented within the cap")
    func interleaveNoStarvation() {
        let books = ["b1"]
        let albums = (0..<20).map { "a\($0)" }
        let r = HomeSections.interleave([books, albums], limit: 6)
        #expect(r.contains("b1"))          // the lone book is not buried
        #expect(r.first == "b1")           // it leads the first round
        #expect(r.count == 6)
    }

    @Test("interleave on empty sources is empty")
    func interleaveEmpty() {
        // interleave is generic since Auftrag K — the empty case pins a type.
        #expect(HomeSections.interleave([[String]](), limit: 5).isEmpty)
        #expect(HomeSections.interleave([[String](), []], limit: 5).isEmpty)
    }
}

/// 6c52b67/a9ad69e: the Continue row's music cap (pure) — 2 music entries
/// max at row limit 10; the only-music exception keeps the row filled.
struct ContinueMusicCapTests {
    @Test("Music capped at 2, freed slots go to books/episodes, limit 10")
    func capsShare() {
        let music = (1...6).map { "m\($0)" }
        let other = (1...10).map { "b\($0)" }
        // Ranked: music first (fresher timestamps — the dominance scenario).
        let ranked = music + other
        let out = HomeSections.cappedShare(ranked, capped: Set(music),
                                           cap: HomeSections.continueMusicCap, limit: 10)
        #expect(out.count == 10)
        #expect(out.filter { $0.hasPrefix("m") } == ["m1", "m2"])   // newest two
        #expect(out.filter { $0.hasPrefix("b") }.count == 8)
    }

    @Test("Only-music stock: the cap yields (an empty row would be worse)")
    func onlyMusicException() {
        let music = (1...5).map { "m\($0)" }
        let out = HomeSections.cappedShare(music, capped: Set(music), cap: 2, limit: 10)
        #expect(out == music)
    }

    @Test("Mixed below the cap passes through untouched; limit still applies")
    func passthrough() {
        let ranked = ["b1", "m1", "b2"]
        #expect(HomeSections.cappedShare(ranked, capped: ["m1"], cap: 2, limit: 10) == ranked)
        let twelve = (1...12).map { "b\($0)" }
        #expect(HomeSections.cappedShare(twelve, capped: [], cap: 2, limit: 10).count == 10)
    }
}
#endif
