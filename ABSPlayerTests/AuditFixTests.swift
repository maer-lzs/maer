// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Regression tests for the correctness-audit fixes (F1, F2, F4, F7, F10).
struct AuditFixTests {

    // MARK: - F1: own server echo must not count as a foreign device

    @Test func ownEchoIsDetectedWithinTolerance() {
        #expect(SyncRules.isOwnServerEcho(serverTime: 150, lastSyncedTime: 150))
        #expect(SyncRules.isOwnServerEcho(serverTime: 152, lastSyncedTime: 150))
        #expect(!SyncRules.isOwnServerEcho(serverTime: 300, lastSyncedTime: 150))
    }

    @Test("Offline bounce scenario: server holds our own last write → no adoption")
    func offlineBounceScenario() {
        // Server: our own 150 with a (clock-ahead) newer timestamp; local: 300.
        let ownEcho = SyncRules.isOwnServerEcho(serverTime: 150, lastSyncedTime: 150)
        let wouldAdopt = SyncRules.shouldAdoptServerState(
            serverTime: 150, serverUpdateMs: 2000, lastKnownServerUpdateMs: 1000, currentTime: 300
        )
        // The raw rule WOULD adopt (that was the bug) — the echo guard vetoes.
        #expect(wouldAdopt)
        #expect(ownEcho)
        // A genuinely foreign write (different position) is NOT an echo.
        #expect(!SyncRules.isOwnServerEcho(serverTime: 500, lastSyncedTime: 150))
    }

    // MARK: - F10: Apple-import dedup keeps the better entry

    @Test func betterAppleProgressPrefersPlayedThenPlayhead() {
        func p(_ playhead: Double, _ played: Bool) -> PodcastImport.AppleProgress {
            PodcastImport.AppleProgress(enclosureURL: "https://x/e.mp3", playhead: playhead,
                                        duration: 100, isPlayed: played)
        }
        #expect(PodcastSubscriptions.isBetterAppleProgress(p(10, true), than: p(90, false)))
        #expect(!PodcastSubscriptions.isBetterAppleProgress(p(90, false), than: p(10, true)))
        #expect(PodcastSubscriptions.isBetterAppleProgress(p(90, false), than: p(10, false)))
        #expect(!PodcastSubscriptions.isBetterAppleProgress(p(10, false), than: p(90, false)))
    }

    // MARK: - F4: feed-URL normalization keeps identity params

    @Test func normalizationCollapsesSchemeVariantsOnly() {
        let a = PodcastSubscriptions.normalizeFeedURL("https://www.example.com/feed/")
        let b = PodcastSubscriptions.normalizeFeedURL("http://example.com/feed")
        #expect(a == b)
        // Tracking params are still stripped.
        let c = PodcastSubscriptions.normalizeFeedURL("https://example.com/feed?utm_source=x&ref=y")
        #expect(c == a)
    }

    @Test("K3 migration: old feedKey -> new feedKey moves progress, second run idempotent")
    func identityQueryMigrationMovesProgress() {
        // A stored show whose feedURL carries an identity param: under the OLD
        // normalization (query fully stripped) its key/guids were derived
        // without the token; the NEW normalization changes the key. migrate()
        // derives keys fresh from the stored raw feedURL, so it must re-key the
        // show + guids and report the progress moves.
        let feedURL = "https://host.tld/feed?token=SECRET"
        let newKey = PodcastSubscriptions.feedKey(feedURL)
        // Old key = what the pre-fix normalization produced (query stripped).
        let oldKey = PodcastSubscriptions.stableHash(
            PodcastSubscriptions.normalizeFeedURL("https://host.tld/feed"))
        #expect(oldKey != newKey, "identity param must change the key")

        let legacy = [PodcastShow(
            id: "feed:\(oldKey)", title: "T", author: nil, artworkURL: nil,
            description: nil, feedURL: feedURL,
            episodes: [PodcastEpisode(guid: "rss:\(oldKey):orig-1", title: "E",
                                      audioURL: "https://x/1.mp3", pubDate: 1, duration: 60,
                                      description: nil, imageURL: nil, chaptersURL: nil)]
        )]

        var moves: [String: String] = [:]
        let (migrated, changed) = PodcastSubscriptions.migrate(legacy) { moves[$0] = $1 }
        #expect(changed)
        #expect(migrated[0].id == "feed:\(newKey)")
        #expect(migrated[0].episodes[0].guid == "rss:\(newKey):orig-1")
        // Progress travels along: old guid -> new guid.
        #expect(moves == ["rss:\(oldKey):orig-1": "rss:\(newKey):orig-1"])

        // Second run: nothing changes, no further moves.
        var secondMoves = 0
        let (again, changedAgain) = PodcastSubscriptions.migrate(migrated) { _, _ in secondMoves += 1 }
        #expect(!changedAgain)
        #expect(secondMoves == 0)
        #expect(again[0].id == migrated[0].id)
    }

    @Test("Feeds differing in identity params stay DISTINCT subscriptions")
    func identityQueryParamsKeepFeedsApart() {
        let tokenA = PodcastSubscriptions.normalizeFeedURL("https://host.tld/feed?token=AAA")
        let tokenB = PodcastSubscriptions.normalizeFeedURL("https://host.tld/feed?token=BBB")
        #expect(tokenA != tokenB)
        let show1 = PodcastSubscriptions.normalizeFeedURL("https://cms.tld/rss?show=1")
        let show2 = PodcastSubscriptions.normalizeFeedURL("https://cms.tld/rss?show=2")
        #expect(show1 != show2)
        // Identity + tracking mixed: identity survives, tracking goes, order canonical.
        let mixed1 = PodcastSubscriptions.normalizeFeedURL("https://h.tld/f?utm=1&token=T")
        let mixed2 = PodcastSubscriptions.normalizeFeedURL("https://h.tld/f?token=T&utm=2")
        #expect(mixed1 == mixed2)
        #expect(PodcastSubscriptions.feedKey("https://h.tld/f?token=A")
            != PodcastSubscriptions.feedKey("https://h.tld/f?token=B"))
    }
}

/// F2: played state for episodes WITHOUT a known duration.
@MainActor
struct PlayedWithoutDurationTests {

    private func item(id: String, duration: Double?) -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "T", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: duration, chapters: nil, tracks: nil
            ),
            addedAt: nil
        )
    }

    /// Isolate the localPosition key and clean it up.
    private func withKey(_ guid: String, _ body: () -> Void) {
        let key = AppStorageKeys.localPosition(guid)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    @Test("Mark-as-played works WITHOUT a duration (was a silent no-op)")
    func markPlayedWithoutDuration() {
        let guid = "rss:test-f2:no-duration"
        withKey(guid) {
            let store = PodcastProgressStore.shared
            store.setPlayed(item(id: guid, duration: 0), true)
            #expect(store.state(guid: guid, duration: 0) == .played)
            // Unplayed tombstone still works.
            store.setPlayed(item(id: guid, duration: 0), false)
            #expect(store.state(guid: guid, duration: 0) == .unplayed)
        }
    }

    @Test func markPlayedWithDurationUnchanged() {
        let guid = "rss:test-f2:with-duration"
        withKey(guid) {
            let store = PodcastProgressStore.shared
            store.setPlayed(item(id: guid, duration: 600), true)
            #expect(store.state(guid: guid, duration: 600) == .played)
            store.setPlayed(item(id: guid, duration: 600), false)
            #expect(store.state(guid: guid, duration: 600) == .unplayed)
        }
    }

    @Test("Sentinel beats a missing duration; normal positions still respect it")
    func sentinelSemantics() {
        let guid = "rss:test-f2:sentinel"
        withKey(guid) {
            let store = PodcastProgressStore.shared
            // A normal position without duration stays unplayed (no fraction derivable).
            UserDefaults.standard.set([120.0, 1000.0], forKey: AppStorageKeys.localPosition(guid))
            #expect(store.state(guid: guid, duration: 0) == .unplayed)
            // The sentinel means played regardless of duration.
            UserDefaults.standard.set([PodcastProgressStore.playedSentinel, 1000.0],
                                      forKey: AppStorageKeys.localPosition(guid))
            #expect(store.state(guid: guid, duration: 0) == .played)
            #expect(store.state(guid: guid, duration: 600) == .played)
        }
    }
}

/// Minimal stub source for LibraryViewModel tests: one library, fixed items,
/// switchable progress failure.
@MainActor
final class MockProvider: AudioProvider {
    var providerId: String { "mock" }
    var capabilities: ProviderCapabilities { [.progressSync] }
    var streamAuthHeaders: [String: String] { [:] }

    var items: [LibraryItem] = []
    var progress: [String: BookProgress] = [:]
    var failProgress = false
    /// Library ids whose item fetch fails (simulates a vanished library).
    var failForLibraryIds: Set<String> = []

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "mock-lib", name: "Mock")]
    }
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        if failForLibraryIds.contains(libraryId) { throw NSError(domain: "mock", code: 404) }
        return items
    }
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        throw NSError(domain: "mock", code: 404)
    }
    func coverURL(forItemId itemId: String) -> URL? { nil }
    func streamURL(forContentPath contentPath: String) -> URL? { nil }
    func fetchAllProgress() async throws -> [String: BookProgress] {
        if failProgress { throw URLError(.notConnectedToInternet) }
        return progress
    }
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}
}

/// F3: a silent local-change refresh must not blank out progress when the
/// server is unreachable.
@MainActor
struct RefreshAfterLocalChangeTests {

    @Test func keepsProgressWhenServerUnreachable() async {
        let provider = MockProvider()
        let item = LibraryItem(
            id: "mock-book",
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Book", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: 1
        )
        provider.items = [item]
        provider.progress = ["mock-book": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 1000)]

        let vm = LibraryViewModel(provider: provider)
        await vm.loadLibrary()
        #expect(vm.entries.first(where: { $0.id == "mock-book" })?.progress?.fraction == 0.5)

        // Server becomes unreachable; a local import triggers the silent refresh.
        provider.failProgress = true
        await vm.refreshAfterLocalChange()
        let after = vm.entries.first(where: { $0.id == "mock-book" })?.progress
        #expect(after?.fraction == 0.5, "progress must survive an offline local-change refresh")
    }
}

/// F7/K6/K7: auto-continue decision core with injected state.
@MainActor
struct PodcastAutoContinueTests {

    private func show(_ id: String, feed: String, episodes: [PodcastEpisode]) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil, description: nil,
                    feedURL: feed, episodes: episodes)
    }

    private func ep(_ guid: String, _ pubDate: Double) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: guid, audioURL: "https://x/\(guid).mp3",
                       pubDate: pubDate, duration: 600, description: nil,
                       imageURL: nil, chaptersURL: nil)
    }

    @Test("Next NEWER unheard of the same show wins; older ones never")
    func picksNextNewer() {
        let shows = [show("s", feed: "f", episodes: [ep("e1", 100), ep("e2", 200), ep("e3", 300)])]
        let picked = PodcastAutoContinue.pick(
            shows: shows, finishedItemId: "e2",
            equivalentIds: { [$0] },
            playState: { _ in .unplayed },
            lastPlayed: { _ in 0 }
        )
        #expect(picked?.id == "e3")
    }

    @Test("K7: same pubDate (batch release) continues via guid tiebreak")
    func samePubDateTiebreak() {
        let shows = [show("s", feed: "f", episodes: [ep("a", 100), ep("b", 100), ep("c", 100)])]
        let picked = PodcastAutoContinue.pick(
            shows: shows, finishedItemId: "b",
            equivalentIds: { [$0] },
            playState: { _ in .unplayed },
            lastPlayed: { _ in 0 }
        )
        // Strictly after "b" in (pubDate, guid) order → "c", never "a".
        #expect(picked?.id == "c")
    }

    @Test("K6: finished rss: id finds its show via the bridge (abspod catalog)")
    func bridgeNormalization() {
        let shows = [show("abs", feed: "f", episodes: [ep("abspod:x:1", 100), ep("abspod:x:2", 200)])]
        let bridge = ["rss:f:orig1": ["rss:f:orig1", "abspod:x:1"],
                      "abspod:x:1": ["abspod:x:1", "rss:f:orig1"],
                      "abspod:x:2": ["abspod:x:2"]]
        let picked = PodcastAutoContinue.pick(
            shows: shows, finishedItemId: "rss:f:orig1",
            equivalentIds: { bridge[$0] ?? [$0] },
            playState: { _ in .unplayed },
            lastPlayed: { _ in 0 }
        )
        // Without normalization step 1 was skipped entirely; now the newer
        // episode of the SAME show is found.
        #expect(picked?.id == "abspod:x:2")
    }

    @Test("Fallback picks the most recently played in-progress episode; the finished twin never")
    func fallbackMostRecentInProgress() {
        let shows = [
            show("s1", feed: "f1", episodes: [ep("s1e1", 100)]),
            show("s2", feed: "f2", episodes: [ep("s2e1", 50), ep("s2e2", 60)]),
        ]
        // Finished s1e1 (no newer episode in s1) → fallback must pick the most
        // recently played in-progress episode across subs.
        let picked = PodcastAutoContinue.pick(
            shows: shows, finishedItemId: "s1e1",
            equivalentIds: { [$0] },
            playState: { item in
                item.id == "s1e1" ? .played : .inProgress(fraction: 0.5, remaining: 300)
            },
            lastPlayed: { id in id == "s2e1" ? 2000 : 1000 }
        )
        #expect(picked?.id == "s2e1")
    }
}
#endif
