// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A podcast list that became a folder keeps the removal marks of its
/// episodes for good: the marks carry the list clock, so every device
/// writes the same folder, and a list older than the age of a mark would
/// lose them at the next merge. A second device with the old episode list
/// would then bring the episodes back and make the folder a mixed list.
struct FolderMarksAgeTests {
    private let day = 86_400.0
    private let now = 1_800_000_000.0

    @Test("a folder from a list last changed 100 days ago stays a folder against the old list of a second device")
    func folderKeepsItsMarks() {
        let clock = now - 100 * day
        let episodes = ["rss:feedA:ep1", "rss:feedA:ep2"]
        // Device A folded the list: the show stands, the episodes carry
        // their marks with the list clock, as `foldPodcastLists` writes them.
        var folder = MaerPlaylistMerge.Entry(name: "Morning", updatedAt: clock,
                                             itemIds: [PodcastFolder.entry(feedKey: "feedA")])
        folder.removed = Dictionary(uniqueKeysWithValues: episodes.map { ($0, clock) })
        folder.added = [PodcastFolder.entry(feedKey: "feedA"): clock]
        // Device B still holds the old list of episodes.
        let old = MaerPlaylistMerge.Entry(name: "Morning", updatedAt: clock, itemIds: episodes)

        let first = MaerPlaylistMerge.merge(local: .init(lists: ["l": folder]), cloud: .init(lists: ["l": old]), now: now)
        #expect(first.lists["l"]?.itemIds == [PodcastFolder.entry(feedKey: "feedA")], "\(first.lists["l"]?.itemIds ?? [])")
        #expect(Set(first.lists["l"]?.removed.keys.map { $0 } ?? []) == Set(episodes), "the folder lost the marks of its episodes")

        // The next merge, with B's old list once more, keeps the folder.
        let second = MaerPlaylistMerge.merge(local: first.snapshot, cloud: .init(lists: ["l": old]), now: now + day)
        #expect(second.lists["l"]?.itemIds == [PodcastFolder.entry(feedKey: "feedA")],
                "the episodes came back: \(second.lists["l"]?.itemIds ?? [])")
    }

    @Test("other marks still age: a plain list drops a mark older than ninety days")
    func plainMarksAge() {
        let kept = MaerPlaylistMerge.aged(["sub:song:1": now - 100 * day, "sub:song:2": now - day],
                                          itemIds: ["sub:song:3"], oldest: now - MaerPlaylistMerge.removalMarkMaxAge)
        #expect(Set(kept.keys) == ["sub:song:2"])
        // In a folder only the marks of episodes stay; a stray other mark ages.
        let inFolder = MaerPlaylistMerge.aged(["rss:feedA:ep1": now - 100 * day, "show:old": now - 100 * day],
                                              itemIds: [PodcastFolder.entry(feedKey: "feedA")],
                                              oldest: now - MaerPlaylistMerge.removalMarkMaxAge)
        #expect(Set(inFolder.keys) == ["rss:feedA:ep1"])
    }

    @Test("the merge asks the one rule for the marks it keeps", .needsTheSources)
    func theMergeAsks() throws {
        let merge = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/MaerPlaylistMerge.swift"), encoding: .utf8))
        #expect(merge.components(separatedBy: "aged(united.removed, itemIds: united.itemIds, oldest: oldest)").count == 2)
        #expect(merge.components(separatedBy: "aged(one.removed, itemIds: one.itemIds, oldest: oldest)").count == 2)
    }
}
#endif
