// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Etappe 3: Home ranks strictly by timestamp, merges sources, de-dups by id.
struct HomeSectionsTests {
    /// Music never stands in Continue, spoken word always does. A music
    /// playlist is music too: in progress it stands in "Listen Again".
    @Test("Musik steht nie in Weiterhoeren, auch keine Playlist; gesprochenes Wort immer")
    func musicNeverInContinue() {
        #expect(!HomeSections.continueAccepts("sub:album:42"))          // server album with 56 %
        #expect(!HomeSections.continueAccepts("jf:album:7"))
        #expect(!HomeSections.continueAccepts("jam:album:9"))          // Jamendo
        #expect(!HomeSections.continueAccepts("lva:netlabel_x#3"))     // a track of an archive album
        #expect(!HomeSections.continueAccepts("lva:netlabel_x", markedForm: .album))
        #expect(HomeSections.continueAccepts("abs-book-id"))           // book with 56 %
        #expect(HomeSections.continueAccepts("rss:feed:guid"))         // episode
        #expect(HomeSections.continueAccepts("lv:1234"))               // LibriVox reading
        #expect(HomeSections.continueAccepts("lva:otr_gunsmoke"))      // a work without a form: reading
        #expect(!HomeSections.continueAccepts("sub:playlist:1"))        // server playlist with 43 %
        #expect(!HomeSections.continueAccepts("jf:playlist:9"))
    }

    /// The caller asks the rule for every started music entry and gives it
    /// no way around: nothing tells it that an entry is a playlist.
    @Test("die Startseite fragt die Regel ohne Ausnahme fuer Playlisten", .needsTheSources)
    func theHomePageAsksWithoutAnException() throws {
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("let music = startedMusic.filter { HomeSections.continueAccepts($0.id) }"))
        #expect(!home.contains("isPlaylist:"), "an exception for playlists is back")
    }

    /// One moment per episode: the newer of local and server stand, on
    /// the ms clock, whatever unit each arrived in.
    @Test("Die Folge hat EINEN Moment fuer Reihe und Karte")
    func oneMomentPerEpisode() {
        #expect(HomeSections.lastPlayedMs(local: 1_000_000, server: 1_700_000_000_000) == 1_700_000_000_000)
        #expect(HomeSections.lastPlayedMs(local: 1_700_000_500, server: 1_700_000_000_000) == 1_700_000_500_000,
                "a local stand in seconds is lifted to ms before it competes")
        #expect(HomeSections.lastPlayedMs(local: 0, server: 0) == 0)
    }

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
        // Package 3: music is just another input to the same merge. Pure recency.
        let r = HomeSections.byRecency([books, episodes, music], limit: 8)
        #expect(r == ["sub:playlist:p1", "b1", "e1", "sub:playlist:p2"])
    }

    // MARK: - Fair interleave (both libraries stay present)

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
        // interleave is generic. The empty case pins a type.
        #expect(HomeSections.interleave([[String]](), limit: 5).isEmpty)
        #expect(HomeSections.interleave([[String](), []], limit: 5).isEmpty)
    }
}

/// The Continue row's order (pure).
struct ContinueRankingTests {
    /// Three sources, three known moments, one order: the newest first
    /// whatever the source, and a source that hands over seconds ranks by
    /// its real moment. Rot-Probe: unnormalized, the seconds entry is last.
    @Test("Weiterhoeren ordnet nach dem echten Moment ueber alle Quellen, eine Uhr")
    func continueRanksByTheRealMomentAcrossSources() {
        let t = 1_700_000_000.0                        // seconds
        let book = [(id: "book", ts: HomeSections.normalizedMs(t + 300))]          // seconds from a server
        let episode = [(id: "episode", ts: HomeSections.normalizedMs((t + 100) * 1000))]
        let album = [(id: "album", ts: HomeSections.normalizedMs((t + 200) * 1000))]
        #expect(HomeSections.byRecency([book, episode, album], limit: 10) == ["book", "album", "episode"])
        // Rot-Probe of the old ranking: the seconds entry sinks to the end.
        let rawBook = [(id: "book", ts: t + 300)]
        let rawEpisode = [(id: "episode", ts: (t + 100) * 1000)]
        let rawAlbum = [(id: "album", ts: (t + 200) * 1000)]
        #expect(HomeSections.byRecency([rawBook, rawEpisode, rawAlbum], limit: 10) == ["album", "episode", "book"])
        #expect(HomeSections.normalizedMs(0) == 0)
        #expect(HomeSections.normalizedMs(1_700_000_000_000) == 1_700_000_000_000)
    }
}
#endif
