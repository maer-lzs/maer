// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing) && DEBUG
import Testing
import Foundation
@testable import Maer

/// A gesture whose open fails takes back all it changed: the standby
/// pointer and the title heard last. A start that stands chooses anew and
/// forgets what was heard last.
@MainActor
@Suite(.serialized)
struct HeardLastWithdrawTests {
    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil), addedAt: nil)
    }

    /// Runs `body` with the two values set, and puts back what stood.
    private func with(pointer: String?, heard: String?, _ body: () async -> Void) async {
        let keptPointer = AppStorageKeys.lastPlayedItemIdValue
        let keptHeard = AppStorageKeys.heardLastItemIdValue
        AppStorageKeys.lastPlayedItemIdValue = pointer
        AppStorageKeys.heardLastItemIdValue = heard
        await body()
        AppStorageKeys.lastPlayedItemIdValue = keptPointer
        AppStorageKeys.heardLastItemIdValue = keptHeard
    }

    @Test("a title heard to its end, then an open that fails: the title is heard last again and the bar names it")
    func aFailedOpenKeepsHeardLast() async {
        await with(pointer: nil, heard: "mso:ended") {
            let coord = PlayerCoordinator(provider: MockProvider())
            // MockProvider throws on the detail fetch: the real failure path.
            await coord.open(item: item("abspod:never-opens"), autoplay: false)
            #expect(AppStorageKeys.heardLastItemIdValue == "mso:ended")
            #expect(AppStorageKeys.lastPlayedItemIdValue == nil)
            #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: AppStorageKeys.lastPlayedItemIdValue,
                                   heardLast: AppStorageKeys.heardLastItemIdValue) == .lastPlayed("mso:ended"))
        }
    }

    @Test("an overtaking gesture that fails gives back the title heard before the first")
    func anOvertakingGestureKeepsHeardLast() async {
        await with(pointer: nil, heard: "mso:ended") {
            let coord = PlayerCoordinator(provider: MockProvider())
            coord.beginOwnSession(item("abspod:B-tapped"), origin: .gesture)
            coord.beginOwnSession(item("abspod:C-overtakes"), origin: .gesture)
            coord.withdrawOwnSession()
            #expect(AppStorageKeys.heardLastItemIdValue == "mso:ended")
            #expect(AppStorageKeys.lastPlayedItemIdValue == nil)
        }
    }

    @Test("a start that stands forgets the title heard last; nothing is left to take back")
    func aStartThatStandsChoosesAnew() async {
        await with(pointer: nil, heard: "mso:ended") {
            let coord = PlayerCoordinator(provider: MockProvider())
            coord.beginOwnSession(item("abspod:B-opens"), origin: .gesture)
            coord.confirmOwnSession()
            coord.withdrawOwnSession()
            #expect(AppStorageKeys.heardLastItemIdValue == nil)
            #expect(AppStorageKeys.lastPlayedItemIdValue == "abspod:B-opens")
        }
    }

    @Test("Fence: what stood before the attempt is one pair, pointer and title heard last", .needsTheSources)
    func onePair() throws {
        let coordinator = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(coordinator.contains("standbyBeforeOpen"))
        #expect(!coordinator.contains("pointerBeforeOpen"), "the pointer alone is still what stood before")
    }
}
#endif
