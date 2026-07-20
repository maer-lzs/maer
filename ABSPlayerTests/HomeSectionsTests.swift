// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
        #expect(HomeSections.interleave([], limit: 5).isEmpty)
        #expect(HomeSections.interleave([[], []], limit: 5).isEmpty)
    }
}
#endif
