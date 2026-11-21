// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Podcast playlists become folders: a folder is a Mär playlist whose
/// entries are shows (`show:<feedKey>`). It stands in the Podcasts tab, a
/// show in a folder leaves the loose grid of subscriptions, the tile counts
/// the new episodes of all its shows and starts the newest unheard episode
/// of each, the page starts in order or shuffled. A podcast list of
/// episodes becomes the folder of their shows once, the same on every
/// device; its unheard episodes go to Up Next once per device.
struct PodcastFolderTests {
    @Test("a show entry names its feed, and a folder holds shows only")
    func entries() {
        #expect(PodcastFolder.entry(feedKey: "abc") == "show:abc")
        #expect(PodcastFolder.feedKey(of: "show:abc") == "abc")
        #expect(PodcastFolder.feedKey(of: "rss:abc:1") == nil)
        #expect(PodcastFolder.isFolder(["show:a", "show:b"]))
        #expect(!PodcastFolder.isFolder([]), "an empty list is no folder")
        #expect(!PodcastFolder.isFolder(["show:a", "rss:b:1"]))
    }

    @Test("a folder is podcasts and stands in the Podcasts tab")
    func home() {
        #expect(MediaFamily.kind(for: "show:abc") == .podcasts)
        #expect(PlaylistHome.of(itemIds: ["show:a", "show:b"], isRoutine: false, markedForm: { _ in nil }) == .podcasts)
    }

    @Test("a list of episodes becomes the folder of their shows: first appearance, no show twice, a show of another folder stays there; the unheard go to Up Next")
    func migration() {
        let ids = ["rss:a:1", "rss:b:1", "rss:a:2", "rss:c:1", "rss:d:1"]
        let migrated = PodcastFolder.migrated(ids,
                                              feedKeyOf: { $0.split(separator: ":")[1].description },
                                              isHeard: { $0 == "rss:a:1" || $0 == "rss:c:1" },
                                              inOtherFolders: ["d"])
        #expect(migrated.entries == ["show:a", "show:b", "show:c"])
        #expect(migrated.toUpNext == ["rss:b:1", "rss:a:2", "rss:d:1"])
        let again = PodcastFolder.migrated(migrated.entries, feedKeyOf: { _ in nil }, isHeard: { _ in false }, inOtherFolders: [])
        #expect(again.entries == migrated.entries && again.toUpNext.isEmpty, "a second run changes nothing")
        #expect(!PodcastFolder.needsMigration(["show:a"]))
        #expect(PodcastFolder.needsMigration(["rss:a:1"]))
        #expect(!PodcastFolder.needsMigration(["rss:a:1", "sub:song:1"]), "a mixed list is no podcast list")
    }

    @Test("a show in a folder leaves the loose grid; the tile counts the new episodes of all its shows")
    func gridAndCount() {
        let folded = PodcastFolder.foldedShows(in: [["show:a", "show:b"], ["rss:x:1"], ["show:c"]])
        #expect(folded == ["a", "b", "c"])
        #expect(PodcastFolder.loose(["a", "x", "c", "y"], folded: folded) == ["x", "y"])
        #expect(PodcastFolder.newCount(["show:a", "show:b"], new: { $0 == "a" ? 2 : 3 }) == 5)
    }

    @Test("a folder starts the newest episode of each show, through the rule of a routine")
    func start() {
        #expect(PodcastFolder.ruleIds(["show:a", "show:b"]) == ["rule:newest:a", "rule:newest:b"])
    }

    @Test("Fence: the Podcasts tab shows folders with a start button, the page starts and shuffles, the grid hides folded shows, a show can go into a folder", .needsTheSources)
    func surfaces() throws {
        let all = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).map { SyncContractFenceTests.stripped($0.1) }.joined(separator: "\n")
        #expect(all.contains("PodcastFolderRow("), "no folder row in the Podcasts tab")
        #expect(all.contains("PodcastFolderPage("), "no folder page")
        #expect(all.contains("PodcastFolder.loose("), "the grid does not hide folded shows")
        #expect(all.contains("PodcastFolder.ruleIds("), "a folder does not start through the routine's rule")
        #expect(all.contains("PodcastFolder.migrated("), "no migration of podcast lists")
        #expect(all.contains("AddShowToFolderSheet("), "a show cannot go into a folder")
    }
}
#endif
