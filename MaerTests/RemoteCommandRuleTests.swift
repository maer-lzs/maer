// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// AirPods double press on songs = next song: for songs only the
/// track commands are on, no jumps by seconds. A song from a free
/// catalog is a song, a catalog audiobook is not (decision 28.09.2026).
/// „Zurueck“ in the first seconds goes to the song before, also across the
/// boundary of an entry; books, podcasts and audiobooks as before; radio
/// nothing.
struct RemoteCommandRuleTests {
    @Test("The table per title: catalog song, catalog audiobook, music, book, podcast, radio")
    func theTable() {
        typealias E = RemoteCommandRule.Enabled
        let songs = E(skip: false, track: true), spoken = E(skip: true, track: true)
        let table: [(String?, RemoteCommandRule.Kind, E)] = [
            ("jam:12345", .songs, songs),                  // Jamendo, music by kind
            ("lva:some_item#3", .songs, songs),            // a song from archive.org
            ("lv:1234", .spoken, spoken),                  // LibriVox audiobook
            ("gut:5884", .spoken, spoken),                 // Gutenberg audiobook
            ("sub:song:9", .songs, songs),                 // music from the server
            ("local:book-1", .spoken, spoken),             // audiobook
            ("rss:feed:ep-1", .spoken, spoken),            // Podcast
            ("radio:station-1", .live, E(skip: false, track: false)),
            (nil, .spoken, spoken),                        // nothing loaded
        ]
        for (id, kind, enabled) in table {
            #expect(RemoteCommandRule.kind(forItem: id) == kind, "\(id ?? "nil")")
            #expect(RemoteCommandRule.enabled(for: kind) == enabled, "\(id ?? "nil")")
        }
        #expect(MediaFamily.allCases.count == 6, "a new family needs a row here")
    }

    /// Music plays the same however it was started: every id a music start
    /// hands the player (a whole album or list, a song alone as shuffle and
    /// top songs play them, from either server) is songs to the one rule,
    /// taken from the providers' own id builders, not typed here.
    @Test("every music start path, album, list and single song of both servers, is songs to the rule")
    func everyMusicStartIsSongs() throws {
        let song = try JSONDecoder().decode(SubsonicSong.self, from: Data(#"{"id":"s1","title":"Song"}"#.utf8))
        let ids = [
            SubsonicProvider.itemId(albumId: "a1"), SubsonicProvider.itemId(playlistId: "p1"),
            SubsonicProvider.songItem(from: song).id,
            JellyfinProvider.itemId(albumId: "a1"), JellyfinProvider.itemId(playlistId: "p1"),
            JellyfinProvider.itemId(songId: "s1"),
            CatalogSongID.make(album: "lva:some_item", index: 2),
        ]
        for id in ids {
            #expect(RemoteCommandRule.kind(forItem: id) == .songs, "\(id) is not songs")
        }
    }

    /// The title key's hop to the next title reads the orders AND the
    /// context, by the end's own rule, and keeps the context when it hops
    /// along it: a shuffled list keeps its rest in the context, and a hop
    /// that read only the orders did nothing there.
    @Test("the hop to the next title reads orders and context by the rule of the title end and keeps the context", .needsTheSources)
    func theSkipReadsTheContext() throws {
        let hop = PlaybackAdvance.next(queueIds: [], contextIds: ["sub:song:2", "sub:song:3"],
                                       isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hop?.id == "sub:song:2" && hop?.origin == .context, "the rule does not reach the context")
        let order = PlaybackAdvance.next(queueIds: ["rss:feed:ep"], contextIds: ["sub:song:2"],
                                         isPlayable: { _ in true }, resolves: { _ in true })
        #expect(order?.id == "rss:feed:ep" && order?.origin == .order, "the orders lost their place in front")
        let coordinator = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(
            "Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        let skip = try #require(ABSPodcastRefreshTests.body(of: "private func nextPlayableTitle()", in: coordinator),
                                "the skip has no resolution of its own name")
        #expect(skip.contains("PlaybackAdvance.next(queueIds: inputs.queueIds, contextIds: inputs.contextIds"),
                "the skip does not read orders and context by the end's rule")
        #expect(coordinator.contains("open(item: next.item, preservesContext: next.fromContext)"),
                "a hop along the context drops it")
        #expect(!coordinator.contains("QueueContinuation.nextPlayable("), "a resolution of the orders alone came back")
    }

    @Test("Back: 1 s goes to the song before, 5 s to the start; a first song with a predecessor goes to the predecessor, the very first to the start")
    func theBackRule() {
        typealias B = RemoteCommandRule.Back
        #expect(RemoteCommandRule.back(withinTrack: 5, trackIndex: 2, hasSongBefore: true) == B.startOfTrack)
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 2, hasSongBefore: false) == B.previousTrack)
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 0, hasSongBefore: true) == B.songBefore,
                "erster Song im Album, davor lief ein anderer: ueber die Grenze zurueck")
        #expect(RemoteCommandRule.back(withinTrack: 1, trackIndex: 0, hasSongBefore: false) == B.startOfItem,
                "der allererste Song: an den Anfang")
        #expect(RemoteCommandRule.back(withinTrack: 5, trackIndex: 0, hasSongBefore: true) == B.startOfTrack)
        #expect(RemoteCommandRule.back(withinTrack: 3, trackIndex: 0, hasSongBefore: true) == B.songBefore,
                "genau drei Sekunden zaehlen noch als Anfang")
    }

    @Test("Only a song that yields to another title is remembered")
    func whatIsRemembered() {
        #expect(RemoteCommandRule.remembersForBack(leaving: "sub:song:1", starting: "sub:song:2"))
        #expect(RemoteCommandRule.remembersForBack(leaving: "jam:1", starting: "sub:song:2"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: "rss:feed:ep-1", starting: "sub:song:2"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: "sub:song:1", starting: "sub:song:1"))
        #expect(!RemoteCommandRule.remembersForBack(leaving: nil, starting: "sub:song:1"))
    }

    @Test("Next after Back: the table of who comes back")
    func whatReturnsWithNext() {
        let table: [(String?, Bool)] = [
            ("sub:song:9", true),          // music from the server
            ("jam:12345", true),           // catalog song
            ("lva:some_item#3", true),     // song from archive.org
            ("lv:1234", false),            // catalog audiobook
            ("local:book-1", false),       // audiobook
            ("rss:feed:ep-1", false),      // Podcast
            ("radio:station-1", false),    // Radio
            (nil, false),                  // nothing played
        ]
        for (id, returns) in table {
            #expect(RemoteCommandRule.returnsWithNext(leaving: id) == returns, "\(id ?? "nil")")
        }
    }

    private func orders() -> PlayQueue {
        PlayQueue(persists: false, equivalents: { [$0] })
    }

    /// Next picks what the app picks: the first playable entry.
    private func next(_ q: PlayQueue) -> String? {
        QueueContinuation.nextPlayable(ids: q.ids, isPlayable: { _ in true }, resolves: { _ in true })
    }

    @Test("Next after Back: the left song sits once at the front, two steps stack in reverse")
    @MainActor
    func theLeftSongWaitsInFront() {
        let q = orders()
        q.playLast("sub:song:x")
        // C played, Back to B: C waits at the front.
        q.returnForNext(leaving: "sub:song:c")
        #expect(q.ids == ["sub:song:c", "sub:song:x"])
        #expect(next(q) == "sub:song:c", "Weiter spielt den verlassenen Song")
        // Back once more, from B to A: B before, C behind.
        q.returnForNext(leaving: "sub:song:b")
        #expect(q.ids == ["sub:song:b", "sub:song:c", "sub:song:x"])
        #expect(next(q) == "sub:song:b")
    }

    @Test("Next after Back: an already queued song sits exactly once at the front afterwards")
    @MainActor
    func neverTwice() {
        let q = orders()
        q.playLast("sub:song:x")
        q.playLast("sub:song:c")
        q.returnForNext(leaving: "sub:song:c")
        #expect(q.ids == ["sub:song:c", "sub:song:x"])
        q.returnForNext(leaving: "sub:song:c")
        #expect(q.ids.filter { $0 == "sub:song:c" }.count == 1)
    }

    @Test("Next after Back: books, podcasts, radio and nothing leave the orders as they are")
    @MainActor
    func spokenStaysOut() {
        let q = orders()
        q.playLast("sub:song:x")
        for left in ["local:book-1", "rss:feed:ep-1", "lv:1234", "radio:station-1"] as [String?] + [nil] {
            q.returnForNext(leaving: left)
        }
        #expect(q.ids == ["sub:song:x"])
    }

    @Test("The way back depends on the rule and on the stack of the session", .needsTheSources)
    func theBackWiring() throws {
        let player = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(player.contains("switchRemoteCommandRule.back(withinTrack:"))
        #expect(player.contains("hasSongBefore:hasSongBefore?()??false"))
        let coordinator = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(coordinator.contains("RemoteCommandRule.remembersForBack(leaving:activeItem?.id,starting:item.id)"))
        #expect(coordinator.contains("self.songsBefore.popLast()"))
        #expect(coordinator.contains("open(item:previous,restart:true,preservesContext:true)"))
        // Next after Back: the id is remembered BEFORE opening (afterwards
        // the running title is already the fetched-back one) and then handed to the one
        // door of the orders.
        #expect(coordinator.contains("privatevarorders:PlayQueue{PlayQueue.shared}"))
        let remember = try #require(coordinator.range(of: "letleft=self.activeItem?.id"))
        let open = try #require(coordinator.range(of: "awaitself.open(item:previous,restart:true,preservesContext:true)"))
        let hand = try #require(coordinator.range(of: "self.orders.returnForNext(leaving:left)"))
        #expect(remember.lowerBound < open.lowerBound && open.lowerBound < hand.lowerBound)
        let press = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"), encoding: .utf8))
        #expect(press.contains("switch RemoteCommandRule.kind(forItem: id, markedForm: playingForm)"),"die Taste fragt dieselbe Regel wie der Sperrbildschirm")
    }

    @Test("The title buttons of the app: songs take the title path, everything else flips chapters")
    func theAppStep() {
        #expect(RemoteCommandRule.appStep(for: .songs) == .title)
        #expect(RemoteCommandRule.appStep(for: .spoken) == .chapter)
        #expect(RemoteCommandRule.appStep(for: .live) == .chapter)
        #expect(RemoteCommandRule.appStep(for: RemoteCommandRule.kind(forItem: "sub:album:1")) == .title)
        #expect(RemoteCommandRule.appStep(for: RemoteCommandRule.kind(forItem: "rss:feed:ep-1")) == .chapter)
        #expect(RemoteCommandRule.appStep(for: RemoteCommandRule.kind(forItem: "local:book-1")) == .chapter)
    }

    @Test("The title buttons are named for what they do: title for songs, otherwise chapter")
    func theKeyLabels() {
        let title = RemoteCommandRule.keyLabels(for: .title), chapter = RemoteCommandRule.keyLabels(for: .chapter)
        #expect(title.back.key == "Previous track" && title.forward.key == "Next track")
        #expect(chapter.back.key == "Previous chapter" && chapter.forward.key == "Next chapter")
        var back = title.back, forward = title.forward
        back.locale = Locale(identifier: "de")
        forward.locale = Locale(identifier: "de")
        #expect(String(localized: back) == "Vorheriger Titel")
        #expect(String(localized: forward) == "Nächster Titel")
    }

    /// Calls that turn a chapter directly, past the one entry `stepTitle`.
    /// Comments do not count, and a call counts with any receiver in front.
    nonisolated static func chapterTurns(in text: String) -> Int {
        let code = SyncContractFenceTests.stripped(text)
        return code.matches(of: #/(?:^|[^A-Za-z0-9_])(?:previousChapter|nextChapter)\(\)/#).count
    }

    @Test("No surface flips past the rule: title buttons and swipe gesture go through stepTitle", .needsTheSources)
    func noSurfaceTurnsChaptersPastTheRule() throws {
        #expect(Self.chapterTurns(in: "viewModel.nextChapter()\ncoordinator.viewModel?.previousChapter()\n// viewModel.nextChapter()") == 2,
                "the finder sees both receivers and skips the comment")
        var turns: [String: Int] = [:]
        var steps = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = Self.chapterTurns(in: text)
            if count > 0 { turns[file.lastPathComponent] = count }
            steps += SyncContractFenceTests.stripped(text).components(separatedBy: "stepTitle(forward:").count - 1
        }
        #expect(turns.isEmpty, "views turn chapters past stepTitle: \(turns)")
        #expect(steps >= 3, "the keys and both swipes call stepTitle, found \(steps)")
        let player = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        let body = try #require(functionBody(of: "func stepTitle(forward: Bool) {", in: player))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(body.contains("switchtitleStep{"))
        #expect(body.contains("jumpToAdjacentTrack(forward:forward)"))
        let flat = player.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(flat.contains("vartitleStep:RemoteCommandRule.AppStep{RemoteCommandRule.appStep(for:RemoteCommandRule.kind(forItem:item?.id,markedForm:playingForm))}"))
        let view = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PlayerView.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        for side in ["back", "forward"] {
            #expect(view.contains("accessibilityLabel(Text(RemoteCommandRule.keyLabels(for:viewModel.titleStep).\(side)))"),
                    "the \(side) key is named by the same rule it acts on")
        }
    }

    @Test("The three kinds and their commands")
    func theKinds() {
        typealias E = RemoteCommandRule.Enabled
        #expect(RemoteCommandRule.enabled(for: .songs) == E(skip: false, track: true))
        #expect(RemoteCommandRule.enabled(for: .spoken) == E(skip: true, track: true))
        #expect(RemoteCommandRule.enabled(for: .live) == E(skip: false, track: false))
    }

    @Test("The commands follow the rule per title, and every incoming command writes a line", .needsTheSources)
    func theWiring() throws {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"),
            encoding: .utf8))
        let update = try #require(functionBody(of: "func updateNowPlayingInfo() {", in: source))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(update.contains("RemoteCommandRule.enabled(for:"))
        for command in ["skipForwardCommand.isEnabled=enabled.skip", "skipBackwardCommand.isEnabled=enabled.skip",
                        "nextTrackCommand.isEnabled=enabled.track", "previousTrackCommand.isEnabled=enabled.track"] {
            #expect(update.contains(command), "\(command)")
        }
        let flat = source.components(separatedBy: .whitespacesAndNewlines).joined()
        for name in ["noteRemoteCommand(\"skipForward\")", "noteRemoteCommand(\"skipBackward\")",
                     "noteRemoteCommand(forward?\"nextTrack\":\"previousTrack\")"] {
            #expect(flat.contains(name), "\(name)")
        }
    }
}
#endif
