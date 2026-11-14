// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A title change keeps the mini player in place, and a title that does
/// not start ends no shuffle. Measured in the simulator: the bar left for
/// 0.3 to 1.2 s at every change, and one dead title ended a shuffle with
/// seven titles left and the bar with it.
@MainActor
struct TitleChangeHoldTests {

    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil),
                    addedAt: nil)
    }

    /// Runs the walk over a list where `dead` do not start.
    private func walk(_ ids: [String], dead: Set<String>, limit: Int = PlayerCoordinator.unstartedSkipLimit)
        async -> (opened: [String], left: [String], unstarted: [String]) {
        var opened: [String] = []
        var left: [String] = []
        let unstarted = await PlayerCoordinator.advance(
            from: item(ids[0]), limit: limit,
            open: { opened.append($0.id); return !dead.contains($0.id) },
            leave: { left.append($0) },
            after: { id in
                guard let i = ids.firstIndex(of: id), i + 1 < ids.count else { return nil }
                return self.item(ids[i + 1])
            })
        return (opened, left, unstarted)
    }

    @Test("a title that does not start is skipped, the next one starts")
    func aDeadTitleIsSkipped() async {
        let run = await walk(["B", "C", "D"], dead: ["B"])
        #expect(run.opened == ["B", "C"], "the walk opened \(run.opened)")
        #expect(run.left == ["B"] && run.unstarted == ["B"], "the dead title stays in the lists: \(run.left)")
    }

    @Test("at most three in a row, then the sequence ends")
    func threeInARowEnd() async {
        let run = await walk(["B", "C", "D", "E", "F"], dead: ["B", "C", "D", "E", "F"])
        #expect(run.opened == ["B", "C", "D"], "the walk opened \(run.opened)")
        #expect(run.unstarted.count == PlayerCoordinator.unstartedSkipLimit)
    }

    @Test("if nothing follows, the sequence ends after the one")
    func nothingFollows() async {
        let run = await walk(["B"], dead: ["B"])
        #expect(run.opened == ["B"] && run.unstarted == ["B"])
        let started = await walk(["B", "C"], dead: [])
        #expect(started.opened == ["B"] && started.left.isEmpty, "a title that starts leaves nothing")
    }

    @Test("Sound without a bar: a model plays and is not the session, or the session has no title")
    func soundWithoutBar() {
        #expect(!SoundWithoutBar.strays(isPlaying: true, isSession: true, hasTitle: true))
        #expect(SoundWithoutBar.strays(isPlaying: true, isSession: false, hasTitle: true))
        #expect(SoundWithoutBar.strays(isPlaying: true, isSession: true, hasTitle: false))
        #expect(!SoundWithoutBar.strays(isPlaying: false, isSession: false, hasTitle: false))
    }

    @Test("across the sequence every view keeps its session, also between two skipped titles")
    func theHoldSpansTheAdvance() {
        #expect(PlayerScreenContent.of(hasSession: false, isLoading: true, loadError: "gone", holdsShown: true) == .held,
                "a skipped title's sentence drops the held session between two opens")
        #expect(PlayerScreenContent.of(hasSession: false, isLoading: false, loadError: nil, holdsShown: true) == .nothing)
    }

    @Test("the mini player holds by the rule of the big player and no longer dips away", .needsTheSources)
    func theMiniHoldsByTheSameRule() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let library = try code("Sources/Views/LibraryView.swift")
        let squeezed = FetchAnswerTests.squeezed(library)
        #expect(squeezed.contains("playerCoordinator.screenContent(holdsShown: miniShown != nil)"),
                "the mini player asks its own rule")
        #expect(squeezed.contains("if let session = miniDisplayed { MiniPlayerBar("), "the bar draws from the coordinator only")
        // An open that hangs holds the bar as long as the detail fetch waits
        // (measured past 10 s): its buttons stay dead, the bar opens the player.
        #expect(squeezed.contains("controlsLive: miniContent == .player"), "the held bar's buttons act on the stopped session")
        #expect(!squeezed.contains(".takesInput(miniContent"), "a hanging open leaves a dead bar")
        let bar = FetchAnswerTests.squeezed(try code("Sources/Views/MiniPlayerBar.swift"))
        // The transport's call ends with its last argument; the modifier right after it is the one that asks.
        #expect(bar.contains("MiniPlayerTransport(viewModel: viewModel"), "the bar draws its buttons elsewhere")
        #expect(bar.contains("onOpenQueue: onOpenQueue) .takesInput(controlsLive)"),
                "the bar's buttons do not ask whether they are live")
        #expect(!library.contains("miniPlayerSwapOffset"), "the bar dips below the screen again")
        let screen = FetchAnswerTests.squeezed(try code("Sources/Views/PlayerScreen.swift"))
        #expect(screen.contains("coordinator.screenContent(holdsShown: shown != nil)")
                    && screen.contains("isLoading: isChangingTitle, loadError: loadError, holdsShown: holdsShown"),
                "a player view holds only while one title loads, not across the titles the advance skips")
        let coordinator = FetchAnswerTests.squeezed(try code("Sources/ViewModels/PlayerCoordinator.swift"))
        #expect(coordinator.contains("Task { await self.advance(to: next) }")
                    && !coordinator.contains("Task { await self.open(item: next, preservesContext: true) }"),
                "the end of a title opens past the walk")
        #expect(coordinator.contains("watchForSoundWithoutBar(newViewModel)"), "a model plays unwatched")
    }
}
#endif
