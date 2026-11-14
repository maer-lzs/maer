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
    @Test("Music never stands in Continue Listening, not even a playlist; spoken word always does")
    func musicNeverInContinue() {
        #expect(!HomeSections.continueAccepts("sub:album:42"))          // server album with 56 %
        #expect(!HomeSections.continueAccepts("jf:album:7"))
        #expect(!HomeSections.continueAccepts("jam:album:9"))          // Jamendo
        #expect(!HomeSections.continueAccepts("lva:netlabel_x#3"))     // a track of an archive album
        #expect(MediaFamily.isMusicByForm("lva:netlabel_x", markedForm: .album), "the marked form decides too")
        #expect(HomeSections.continueAccepts("abs-book-id"))           // book with 56 %
        #expect(HomeSections.continueAccepts("rss:feed:guid"))         // episode
        #expect(HomeSections.continueAccepts("lv:1234"))               // LibriVox reading
        #expect(HomeSections.continueAccepts("lva:otr_gunsmoke"))      // a work without a form: reading
        #expect(!HomeSections.continueAccepts("sub:playlist:1"))        // server playlist with 43 %
        #expect(!HomeSections.continueAccepts("jf:playlist:9"))
    }

    /// The caller asks the rule for every started music entry and gives it
    /// no way around: nothing tells it that an entry is a playlist. What the
    /// rule turns away goes to "Listen Again"; the Continue row ranks books
    /// and episodes only, so no music stream can slip back into it.
    @Test("the start page asks the rule for playlists without exception", .needsTheSources)
    func theHomePageAsksWithoutAnException() throws {
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("startedMusic.filter { !HomeSections.continueAccepts($0.id) }"))
        #expect(home.contains("HomeSections.byRecency([books, episodesShown], limit: 10)"),
                "the Continue row takes a third stream again")
        #expect(home.contains("HomeSections.byRecency([books, episodesShown], limit: 200)"),
                "the full page takes a third stream again")
        #expect(!home.contains("isPlaylist:"), "an exception for playlists is back")
    }

    /// The provider's item cache as the witness sees it.
    @MainActor final class ItemCache {
        var items: [String: String]
        var fetches: [String] = []
        var late: [String] = []
        init(_ items: [String: String]) { self.items = items }
    }

    /// A clock the witness moves.
    @MainActor final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    /// A playlist started on another device, after a cold start: the
    /// provider has never met its id, so the plain resolver says nil. It is
    /// fetched and then stands in the row; only what still does not resolve
    /// stays out, and it is counted. A failure is no knowledge: the id waits
    /// its holdback and is asked again after it.
    @Test("a started playlist this session has never seen stands in Listen Again after the fetch")
    @MainActor
    func anUnseenStartedPlaylistIsFetchedIntoTheRow() async {
        let clock = Clock()
        let fetcher = ListenAgainFetch(now: { clock.now })
        let cache = ItemCache(["sub:album:1": "Album"])
        let ids = ["sub:album:1", "sub:playlist:7", "sub:playlist:gone"]
        let toFetch = fetcher.plan(ids.filter { cache.items[$0] == nil })
        #expect(toFetch == ["sub:playlist:7", "sub:playlist:gone"], "a known id costs no request")
        await fetcher.fetch(toFetch, onLate: { _ in }) { id in
            await MainActor.run {
                cache.fetches.append(id)
                if id == "sub:playlist:7" { cache.items[id] = "Playlist" }
                return cache.items[id] != nil
            }
        }
        let out = HomeSections.resolveStarted(ids, resolve: { cache.items[$0] })
        #expect(out.items == ["Album", "Playlist"], "the unseen playlist stands in the row")
        #expect(out.missing == ["sub:playlist:gone"], "what the server does not know is counted")
        #expect(fetcher.plan(out.missing).isEmpty, "a failed id waits its holdback")
        clock.now = clock.now.addingTimeInterval(FetchHoldback.seconds + 1)
        #expect(fetcher.plan(out.missing) == ["sub:playlist:gone"], "after the holdback it is asked again")
    }

    /// A server that answers slowly or not at all: the start page renders
    /// after the budget, and the id on its way is not asked a second time.
    @Test("a hanging fetcher holds the start page for the budget at most")
    @MainActor
    func aHangingFetchWaitsAtMostTheBudget() async {
        let fetcher = ListenAgainFetch()
        let started = Date()
        await fetcher.fetch(["sub:playlist:hang"], budget: SourceBudgetTests.budget, onLate: { _ in }) { _ in
            try? await Task.sleep(for: .seconds(SourceBudgetTests.hanging))
            return false
        }
        let waited = Date().timeIntervalSince(started)
        #expect(waited < SourceBudgetTests.budget + 2, "waited \(waited) s for a hanging fetch")
        #expect(fetcher.plan(["sub:playlist:hang"]).isEmpty, "an id on its way is not asked twice")
    }

    /// The answer that comes after the budget: the row learns it without a
    /// further pass.
    @Test("a late answer arrives in the row by itself")
    @MainActor
    func aLateAnswerJoinsTheRow() async {
        let fetcher = ListenAgainFetch()
        let cache = ItemCache([:])
        await fetcher.fetch(["sub:playlist:late"], budget: SourceBudgetTests.budget, onLate: { ids in
            await MainActor.run { cache.late += ids }
        }) { id in
            try? await Task.sleep(for: .seconds(SourceBudgetTests.late))
            return true
        }
        #expect(cache.late.isEmpty, "the page stopped waiting before the answer")
        for _ in 0..<40 where cache.late.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        #expect(cache.late == ["sub:playlist:late"], "the late answer reached the row")
    }

    @Test("per pass at most the cap")
    @MainActor
    func thePlanIsCapped() {
        let ids = (0..<20).map { "sub:playlist:cap\($0)" }
        #expect(ListenAgainFetch().plan(ids) == (0..<6).map { "sub:playlist:cap\($0)" })
    }

    /// The start page fetches through that helper and logs the count after
    /// resolving; a plain `compactMap` drops an unseen id without a trace,
    /// a fetch outside the budget holds the whole page, and the late answer
    /// goes to the late store.
    @Test("the start page fetches under the budget, capped, and counts after resolving", .needsTheSources)
    func theHomePageFetchesWhatItCannotResolve() throws {
        let home = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"), encoding: .utf8))
        #expect(home.contains("ListenAgainFetch.planPass("))
        #expect(home.contains("await ListenAgainFetch.fetchPass(toFetch"))
        #expect(home.components(separatedBy: "fetchItemDetail(").count - 1 == 1,
                "the start page fetches in one place")
        #expect(home.contains("HomeSections.resolveStarted(pendingStarted, resolve: resolveItem)"))
        #expect(home.contains("HOME listenAgain started="))
        #expect(!home.contains("subtracting(knownAlbumIds).sorted().compactMap"), "a silent drop is back")
        let fetch = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ListenAgainFetch.swift"), encoding: .utf8))
        #expect(fetch.contains("LateMusicValues.shared.addRecentAlbums(late.compactMap(resolve))"),
                "a late answer no longer reaches the row")
    }

    /// One moment per episode: the newer of local and server stand, on
    /// the ms clock, whatever unit each arrived in.
    @Test("The episode has ONE moment for row and card")
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
    /// its real moment. Red probe: unnormalized, the seconds entry is last.
    @Test("Continue Listening orders by the real moment across all sources, one clock")
    func continueRanksByTheRealMomentAcrossSources() {
        let t = 1_700_000_000.0                        // seconds
        let book = [(id: "book", ts: HomeSections.normalizedMs(t + 300))]          // seconds from a server
        let episode = [(id: "episode", ts: HomeSections.normalizedMs((t + 100) * 1000))]
        let album = [(id: "album", ts: HomeSections.normalizedMs((t + 200) * 1000))]
        #expect(HomeSections.byRecency([book, episode, album], limit: 10) == ["book", "album", "episode"])
        // Red probe of the old ranking: the seconds entry sinks to the end.
        let rawBook = [(id: "book", ts: t + 300)]
        let rawEpisode = [(id: "episode", ts: (t + 100) * 1000)]
        let rawAlbum = [(id: "album", ts: (t + 200) * 1000)]
        #expect(HomeSections.byRecency([rawBook, rawEpisode, rawAlbum], limit: 10) == ["album", "episode", "book"])
        #expect(HomeSections.normalizedMs(0) == 0)
        #expect(HomeSections.normalizedMs(1_700_000_000_000) == 1_700_000_000_000)
    }
}
#endif
