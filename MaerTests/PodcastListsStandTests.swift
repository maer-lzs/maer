// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A podcast list that stays a list (episodes of the own Audiobookshelf, a
/// mixed list, a rescued version) stands on the Podcasts tab, in the one
/// name list under the folders; a folder stands in the folder row only.
struct PodcastListsStandTests {
    private func list(_ id: String, _ items: [String]) -> MaerPlaylists.Playlist {
        MaerPlaylists.Playlist(id: id, name: id, updatedAt: 1_700_000_000, itemIds: items)
    }

    @Test("the name list takes every podcast list that is no folder; a folder stays in its own row")
    func nameListsLeaveTheFolders() {
        let folder = list("folder", [PodcastFolder.entry(feedKey: "feedA"), PodcastFolder.entry(feedKey: "feedB")])
        let abs = list("abs", ["abspod:li_1:ep_1"])
        let mixed = list("mixed", ["rss:feedA:ep1", "abspod:li_1:ep_2"])
        let shown = PodcastFolder.nameLists([folder, abs, mixed], itemIds: \.itemIds).map(\.id)
        #expect(shown == ["abs", "mixed"], "\(shown)")
        #expect(PodcastFolder.nameLists([folder], itemIds: \.itemIds).isEmpty, "a tab with folders only shows no name list")
    }

    @Test("the Podcasts tab draws the name list under the folders, and the name list leaves the folders out", .needsTheSources)
    func theTabDrawsIt() throws {
        let tab = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PodcastsView.swift"), encoding: .utf8))
        #expect(tab.contains("PlaylistHomeSection(home: .podcasts, playerCoordinator: playerCoordinator)"),
                "a podcast list that stays a list stands on no surface")
        let section = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/PlaylistNameList.swift"), encoding: .utf8))
        #expect(section.contains("PodcastFolder.nameLists(SharedRows.playlists(at: home), itemIds: \\.itemIds)"),
                "the name list shows the folders a second time")
    }
}
#endif
