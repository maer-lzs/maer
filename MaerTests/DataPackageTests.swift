// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The data package of 3.9: the moment of "newest" in the unit of the
/// episodes, no feed address in a key name, the moment of the walk over the
/// old keys only after the table was read, and no earlier pass over a later
/// one in the rows of Continue.
struct DataPackageTests {
    // MARK: The moment of "newest" (automatic download)

    @Test("the moment of newest is stored in seconds and compared in milliseconds: an episode from before switching on stays out")
    func theCutoffIsInMilliseconds() {
        let switchedOnSeconds: Double = 1_800_000_000
        #expect(PodcastAutoDownloadRules.cutoffMs(storedSeconds: switchedOnSeconds) == 1_800_000_000_000)
        #expect(PodcastAutoDownloadRules.cutoffMs(storedSeconds: nil) == 0, "never switched on: everything unheard")
        let before = PodcastEpisode(guid: "old", title: "Old", audioURL: "https://example.org/old.mp3",
                                    pubDate: 1_799_000_000_000, duration: 60)
        let after = PodcastEpisode(guid: "new", title: "New", audioURL: "https://example.org/new.mp3",
                                   pubDate: 1_800_500_000_000, duration: 60)
        let wanted = PodcastAutoDownloadRules.wanted(
            [before, after], direction: .newest,
            since: PodcastAutoDownloadRules.cutoffMs(storedSeconds: switchedOnSeconds), state: { _ in .unplayed })
        #expect(wanted == ["new"], "switching on newest does not pull the backlog")
    }

    @Test("Fence: the run reads the moment through the rule", .needsTheSources)
    func theRunReadsTheCutoff() throws {
        let helpers = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastHelpers.swift"), encoding: .utf8))
        let since = try #require(helpers.range(of: "static func since(_ showId: String) -> Double {"))
        #expect(helpers[since.upperBound...].prefix(300).contains("PodcastAutoDownloadRules.cutoffMs("))
    }

    // MARK: No feed address in a key name (feed artwork)

    @Test("the artwork of a feed is noted under the key of its address, never the address; an entry under the address goes")
    @MainActor func noAddressInAKeyName() async throws {
        let suite = "feed-artwork-key-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ExternalSources.feedArtwork.storageKey
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let old = "https://feeds.example/old.xml?token=s3cr3t-old"
        let now = Date().timeIntervalSince1970
        _ = Artwork.Memo.remember("feed|" + old, value: nil, until: now + 3600, now: now, defaults: defaults)
        let feed = "https://feeds.example/show.xml?token=s3cr3t"
        let host = StatusHost(status: 404)
        let service = FeedArtworkService(suite: suite)
        _ = await service.artworkURL(feedURL: feed, fetch: { await host.answer($0) })
        let keys = Artwork.Memo.entries(prefix: "feed|", defaults: defaults).keys
        #expect(await host.asked == 1, "the precondition: the service asked")
        #expect(!keys.contains { $0.contains("s3cr3t") }, "a key name carries the secret: \(keys.sorted())")
        #expect(keys.contains(PodcastIdentity.feedKey(feed)), "the answer is noted under the key of the address")
    }

    // MARK: The walk over the old keys

    @Test("Fence: the moment of the walk is written only after the table was read", .needsTheSources)
    func theWalkIsNotedAfterTheRead() throws {
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/ListeningStore.swift"), encoding: .utf8))
        let walk = try #require(store.range(of: "static func legacyWalk("))
        #expect(!store[walk.upperBound...].prefix(500).contains("forKey: legacyWalkKey)"),
                "reading the old keys notes the moment before the table is read")
        let mirror = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Storage/StandMirror.swift"), encoding: .utf8))
        let read = try #require(mirror.range(of: "flushed: try await store.allFlushed())"))
        let noted = try #require(mirror.range(of: "ListeningStore.noteLegacyWalk("), "the walk's moment is noted nowhere")
        #expect(read.upperBound <= noted.lowerBound || mirror[..<noted.lowerBound].contains("legacy.backups.isEmpty"),
                "the moment is noted before the table was read")
    }

    // MARK: The rows of Continue

    @Test("a pass older than the rows written does not write: the rows of a server left stay out")
    func anEarlierPassDoesNotWrite() {
        #expect(!ContinueBySource.takesPass(passAtMs: 1_000, storedPassAtMs: 2_000), "an earlier pass writes the server left back")
        #expect(ContinueBySource.takesPass(passAtMs: 2_000, storedPassAtMs: 2_000), "a pass that keeps the moment writes")
        #expect(ContinueBySource.takesPass(passAtMs: 3_000, storedPassAtMs: 2_000))
        #expect(ContinueBySource.takesPass(passAtMs: 1_000, storedPassAtMs: nil))
    }

    @Test("Fence: the writer asks the rule before it saves", .needsTheSources)
    func theWriterAsksTheRule() throws {
        let writer = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ContinueRowsWriter.swift"), encoding: .utf8))
        let asked = try #require(writer.range(of: "ContinueBySource.takesPass("))
        let saved = try #require(writer.range(of: ".save()"))
        #expect(asked.lowerBound < saved.lowerBound)
    }
}
#endif
