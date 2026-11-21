// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Repeat, music only: off, the list, one song. A tap goes round; the state
/// stays until someone changes it and belongs to this device. At a song's
/// natural end one song plays it again; with the list, what was started
/// begins again once nothing else follows. The orders of Up Next play
/// before the list starts again, a skip goes on to the next song.
@MainActor
@Suite(.serialized)
struct RepeatModeTests {
    @Test("a tap goes off, list, song, off; an unknown stored value is off")
    func cycle() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
        #expect(RepeatMode.stored(nil) == .off)
        #expect(RepeatMode.stored("one") == .one)
        #expect(RepeatMode.stored("sometimes") == .off)
    }

    @Test("the step at a title's end: the same song, the list again, or the usual way on")
    func steps() {
        func step(_ mode: RepeatMode, music: Bool = true, natural: Bool = true, found: Bool = false, whole: Int = 3) -> RepeatRule.Step {
            RepeatRule.step(mode: mode, isMusic: music, natural: natural, cascadeFound: found, wholeCount: whole)
        }
        #expect(step(.one) == .same)
        #expect(step(.one, found: true) == .same, "one song plays again before the orders")
        #expect(step(.one, natural: false) == .cascade, "a skip goes on")
        #expect(step(.one, music: false) == .cascade, "an audiobook never repeats")
        #expect(step(.all) == .restart, "nothing follows: the list again")
        #expect(step(.all, found: true) == .cascade, "orders and the rest play first")
        #expect(step(.all, whole: 0) == .cascade, "nothing was started as a list")
        #expect(step(.all, music: false) == .cascade)
        #expect(step(.off) == .cascade)
    }

    @Test("the context keeps the whole list a start handed over, beside its rest; a single start forgets it")
    func contextKeepsTheWholeList() {
        let context = PlaybackContext()
        context.replace(ids: ["sub:song:2", "sub:song:3"], source: "Album", whole: ["sub:song:1", "sub:song:2", "sub:song:3"])
        #expect(context.whole == ["sub:song:1", "sub:song:2", "sub:song:3"])
        #expect(context.ids == ["sub:song:2", "sub:song:3"])
        context.clear()
        #expect(context.whole.isEmpty)
    }

    @Test("a stored context of a build without the whole list still reads")
    func oldStoredContextReads() throws {
        let old = Data(#"{"version":1,"sourceTitle":"Album","ids":["sub:song:2"]}"#.utf8)
        let stored = try JSONDecoder().decode(PlaybackContext.Stored.self, from: old)
        #expect(stored.ids == ["sub:song:2"])
        #expect(stored.whole == nil)
    }

    private static func song(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(metadata: nil, duration: 200, chapters: nil, tracks: nil), addedAt: nil)
    }

    @Test("the coordinator names and plays what repeat says: the same song, then the list from its start")
    func coordinatorFollowsRepeat() {
        let keptMode = AppStorageKeys.musicRepeatModeValue
        let context = PlaybackContext.shared
        let keptIds = context.ids, keptWhole = context.whole, keptSource = context.sourceTitle
        defer {
            AppStorageKeys.musicRepeatModeValue = keptMode
            context.replace(ids: keptIds, source: keptSource, whole: keptWhole)
        }
        let coordinator = PlayerCoordinator(provider: RSSProvider.shared)
        coordinator.known = { Self.song($0) }
        let run = "repeat-\(UUID().uuidString.prefix(6))"
        let first = "sub:song:\(run)-1", second = "sub:song:\(run)-2"
        context.replace(ids: [], source: "Album", whole: [first, second])

        AppStorageKeys.musicRepeatModeValue = .one
        #expect(coordinator.resolveAdvance(after: second)?.id == second, "one song: the same again")
        #expect(coordinator.resolveAdvance(after: second, natural: false)?.id != second, "a skip goes on")
        AppStorageKeys.musicRepeatModeValue = .all
        #expect(coordinator.resolveAdvance(after: second)?.id == first, "the list from its start")
        AppStorageKeys.musicRepeatModeValue = .off
        #expect(coordinator.resolveAdvance(after: second) == nil, "off: the end")
    }

    @Test("Fence: the player's music row carries the repeat button beside the sound, the system's command and the car follow it", .needsTheSources)
    func surfaces() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let all = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).map { SyncContractFenceTests.stripped($0.1) }.joined(separator: "\n")
        #expect(all.contains("RepeatButton("), "no repeat button in the player")
        #expect(all.contains("changeRepeatModeCommand"), "the system's command does not reach repeat")
        #expect(try code("Sources/CarPlay/CarPlaySceneDelegate.swift").contains("CPNowPlayingRepeatButton"), "the car has no repeat")
        #expect(try code("Sources/ViewModels/PlayerCoordinator.swift").contains("RepeatRule.step("), "the end does not ask the rule")
    }
}
#endif
