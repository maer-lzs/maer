// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing) && DEBUG
import Testing
import Foundation
@testable import ABSPlayer

/// The standby follows the fresh truth WITHOUT an app restart. The
/// transitions, not the end states (the start path was already proven).
@MainActor
struct StandbyLiveRefreshTests {

    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: media(id), addedAt: nil)
    }
    private func detail(_ id: String) -> LibraryItemDetail {
        LibraryItemDetail(id: id, media: media(id), userMediaProgress: nil)
    }
    private func media(_ title: String) -> LibraryItemMedia {
        LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil)
    }

    @Test("A held pointer that turned finished clears the standby live")
    func heldFinishedClearsLive() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: AppStorageKeys.localPosition(id))
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        // Finished by numbers arrives (adopted positions or local finish).
        defaults.set([100.0, 1000.0, 100.0], forKey: AppStorageKeys.localPosition(id))

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
        #expect(defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == nil)
    }

    @Test("A PLAYING session is never torn down — it claims instead")
    func playingSessionIsProtected() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: AppStorageKeys.localPosition(id))
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        coord.viewModel?.isPlaying = true
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        defaults.set([100.0, 1000.0, 100.0], forKey: AppStorageKeys.localPosition(id))

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem?.id == id)   // untouched
        #expect(coord.viewModel != nil)
    }

    @Test("MIRROR: a touched but PAUSED session follows the fresher truth (finish clears)")
    func touchedPausedSessionFollowsTheMirror() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: AppStorageKeys.localPosition(id))
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        coord.viewModel?.eventSinceLoad = true   // touched — but paused
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        defaults.set([100.0, 1000.0, 100.0], forKey: AppStorageKeys.localPosition(id))

        await coord.refreshStandbyFromTruth()

        // Finished ⇒ both clear. "both empty" is also
        // "the same piece".
        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
    }

    @Test("A foreign standby tombstone clears the paused standby live")
    func foreignTombstoneClearsLive() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId) }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)   // adopted tombstone

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
    }

    @Test("A finished FOREIGN pointer is never adopted live (guard parity)")
    func finishedForeignPointerIsNotAdopted() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: AppStorageKeys.localPosition(id))
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        defaults.set([100.0, 1000.0, 100.0], forKey: AppStorageKeys.localPosition(id))

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)   // nothing appeared
    }
}
#endif
