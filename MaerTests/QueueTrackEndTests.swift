// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A music server song plays from the queue whether or not this run has
/// listed it, a heard song starts again from 0, the full player never spins
/// over nothing, and the player's music tools know both servers.
struct QueueTrackEndTests {
    /// Comments out, whitespace runs squeezed to one space: the fences look
    /// for CALLS, and a formatter's line break must not tear them.
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    // MARK: - The queue

    @Test("Warteschlange: ein Musik-Server-Titel spielt aus sich selbst, sobald sein Server eingerichtet ist")
    func aServerSongResolvesOnDemand() {
        for id in ["jf:song:9", "sub:song:9", "jf:album:4", "sub:album:4"] {
            let resolved = SyncCarried.resolve(itemId: id, carried: nil, known: nil, sourceConfigured: true).item
            #expect(resolved?.id == id, "\(id) with its server set up is playable from its id")
            #expect(resolved?.media == nil, "a stub: the player fetches the detail on open")
        }
        // The snapshot names it until the detail is there.
        let carried = CarriedItem(id: "jf:song:9", title: "Heroes", subtitle: "Bowie", duration: 372)
        let named = SyncCarried.resolve(itemId: "jf:song:9", carried: carried, known: nil, sourceConfigured: true).item
        #expect(named?.title == "Heroes" && named?.author == "Bowie")
        // Without its server it stays unavailable, with its reason.
        #expect(SyncCarried.resolve(itemId: "jf:song:9", carried: nil, known: nil, sourceConfigured: false).reason
                == .sourceNotConfigured(source: "jf:"))
        // What is NOT a music server's stays as it was.
        #expect(SyncCarried.resolve(itemId: "li_abc", carried: nil, known: nil, sourceConfigured: true).reason == .notInLibrary)
        #expect(SyncCarried.resolve(itemId: "rss:feed:ep", carried: nil, known: nil, sourceConfigured: true).reason == .showNotFollowed)
        #expect(SyncCarried.resolve(itemId: "local:/x.mp3", carried: nil, known: nil, sourceConfigured: true).reason == .fileNotOnDevice)
    }

    @Test("Warteschlange: die eine Frage resolvesOnDemand, Katalog immer, Musik-Server nur eingerichtet")
    func theOnDemandQuestion() {
        #expect(SyncCarried.resolvesOnDemand("lv:12", sourceConfigured: false))
        #expect(SyncCarried.resolvesOnDemand("jf:song:1", sourceConfigured: true))
        #expect(SyncCarried.resolvesOnDemand("sub:song:1", sourceConfigured: true))
        #expect(!SyncCarried.resolvesOnDemand("jf:song:1", sourceConfigured: false))
        #expect(!SyncCarried.resolvesOnDemand("li_abc", sourceConfigured: true))
        #expect(!SyncCarried.resolvesOnDemand("abspod:ep", sourceConfigured: true))
        #expect(!SyncCarried.resolvesOnDemand("radio:rb:x", sourceConfigured: true))
    }

    @Test("Warteschlange: das Weiterschalten findet einen Jellyfin-Titel, den dieser Lauf nie gelistet hat")
    func theAdvanceFindsAnUnlistedSong() {
        // The advance's own rule with the seam's answer as `resolves`, the
        // way `PlayerCoordinator.advanceInputs` wires it; nothing is known locally.
        let resolves: (String) -> Bool = {
            SyncCarried.resolve(itemId: $0, carried: nil, known: nil, sourceConfigured: true).item != nil
        }
        #expect(QueueContinuation.nextPlayable(ids: ["local:/gone.mp3", "jf:song:7", "sub:song:8"],
                                               isPlayable: { _ in true }, resolves: resolves) == "jf:song:7",
                "was nil: `ADVANCE ends: orders=3 context=0, none playable`")
    }

    // MARK: - The end of a title

    @Test("Titelende: fehlt das Wort des Servers, entscheidet die lokale Marke, und ein gehoerter Titel startet bei 0")
    func aHeardSongStartsAgain() {
        // The measured case: a Jellyfin song of 272 s, heard to its end,
        // the detail without progress. It opened at 272 and ended at once.
        let heard: [Double] = [272, 1_780_000_000_000, 272]
        #expect(PlayerCoordinator.isFinishedAtOpen(serverFinished: nil, localMark: heard, duration: 272))
        #expect(PlayerCoordinator.resolvesToRestart(
            explicitRestart: false, autoplay: true,
            isFinished: PlayerCoordinator.isFinishedAtOpen(serverFinished: nil, localMark: heard, duration: 272)))
        // Played by the sentinel, and by today's duration for an old mark.
        #expect(PlayerCoordinator.isFinishedAtOpen(serverFinished: nil,
                                                   localMark: [ProgressMark.playedSentinel, 1], duration: 0))
        #expect(PlayerCoordinator.isFinishedAtOpen(serverFinished: nil, localMark: [271.5, 1], duration: 272))
        // In the middle, or no mark: resume, not restart.
        #expect(!PlayerCoordinator.isFinishedAtOpen(serverFinished: nil, localMark: [120, 1, 272], duration: 272))
        #expect(!PlayerCoordinator.isFinishedAtOpen(serverFinished: nil, localMark: nil, duration: 272))
        // The server's word wins where it has one, both ways.
        #expect(!PlayerCoordinator.isFinishedAtOpen(serverFinished: false, localMark: heard, duration: 272))
        #expect(PlayerCoordinator.isFinishedAtOpen(serverFinished: true, localMark: nil, duration: 272))
        // A silent restore still never restarts.
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: false, isFinished: true))
    }

    @Test("Titelende: der Start fragt die Regel mit der lokalen Marke, nicht nur den Server")
    func theStartAsksTheRule() throws {
        let coordinator = try Self.source("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(coordinator.contains("isFinished: Self.isFinishedAtOpen("))
        #expect(coordinator.contains("localMark: ListeningStore.backup(item.id) ?? ListeningStore.flushed(item.id)"),
                "the same witnesses, in the same order, the player takes its start position from")
        #expect(!coordinator.contains("isFinished: detail.userMediaProgress?.isFinished == true"))
    }

    // MARK: - The full player

    @Test("Grosser Player: ein Ladekreis nur, wenn etwas laedt; ohne Gegenstand ist es nichts")
    func theScreenNeverSpinsOverNothing() {
        #expect(PlayerScreenContent.of(hasSession: true, isLoading: true, loadError: "x") == .player)
        #expect(PlayerScreenContent.of(hasSession: false, isLoading: true, loadError: nil) == .loading)
        #expect(PlayerScreenContent.of(hasSession: false, isLoading: false, loadError: "Offline.") == .error("Offline."))
        #expect(PlayerScreenContent.of(hasSession: false, isLoading: false, loadError: nil) == .nothing,
                "the state after `STANDBY cleared live`: it spun forever")
    }

    @Test("Grosser Player: er schliesst auf nichts, und nur der aktuelle Oeffnungslauf beendet das Laden")
    func thePlayerClosesOnNothing() throws {
        let overlay = try Self.source("Sources/Views/FullPlayerOverlay.swift")
        #expect(overlay.contains(".onChange(of: coordinator.screenContent == .nothing, initial: true)"))
        #expect(overlay.contains("if isEmpty { slideOutAndDismiss() }"))
        let screen = try Self.source("Sources/Views/PlayerScreen.swift")
        #expect(screen.contains("switch coordinator.screenContent"))
        #expect(screen.components(separatedBy: "ProgressView(").count - 1 == 1,
                "one spinner, the one for loading; the bare one is gone")
        let coordinator = try Self.source("Sources/ViewModels/PlayerCoordinator.swift")
        // A stale open ending the load while a newer one loads would read as
        // nothing and close the player under the newer one.
        #expect(coordinator.contains("defer { if openGate.isCurrent(generation) { isLoading = false } }"))
        #expect(!coordinator.contains("defer { isLoading = false }"))
    }

    @Test("Grosser Player: Als gehoert markieren leert die Sitzung nur, wenn nichts folgt")
    func markingHandsOverWhenSomethingFollows() throws {
        let coordinator = try Self.source("Sources/ViewModels/PlayerCoordinator.swift")
        let start = try #require(coordinator.range(of: "func markPlayedAndAdvance(itemId: String) {"))
        let body = String(coordinator[start.upperBound...].prefix(600))
        let leave = try #require(body.range(of: "leaveBothLists(itemId)"))
        let ask = try #require(body.range(of: "if resolveAdvance(after: itemId) == nil {"))
        let clear = try #require(body.range(of: "viewModel = nil"))
        #expect(leave.lowerBound < ask.lowerBound, "out of the lists before asking what follows")
        #expect(ask.lowerBound < clear.lowerBound, "the session is cleared only inside the nothing-follows branch")
    }

    // MARK: - Music of both servers

    @Test("Musik: die Werkzeuge des Players kennen beide Server, ein Jellyfin-Hoerbuch ist keine Musik")
    func serverMusicIsBothServers() {
        for id in ["sub:song:1", "sub:album:1", "jf:song:1", "jf:album:1", "jf:playlist:1"] {
            #expect(MusicSourceRule.isServerMusic(id), "\(id)")
        }
        for id in ["jf:book:b1", "li_abc", "lv:12", "rss:f:g", "local:/a.mp3", "radio:rb:x"] {
            #expect(!MusicSourceRule.isServerMusic(id), "\(id)")
        }
    }

    @Test("Musik: kein isSubsonic, wo Musik gemeint ist, und der Liedtext fragt den Server des Titels")
    func noSubsonicStandsForMusic() throws {
        var all = ""
        for file in ProjectFileIntegrityTests.sourceFiles() where !file.path.hasSuffix("/ItemNamespace.swift")
            && !file.path.hasSuffix("/MusicSourceRule.swift") {
            all += Self.squeezed(try String(contentsOf: file, encoding: .utf8)) + "\n"
        }
        #expect(all.contains("MusicSourceRule.isServerMusic("), "the precondition: the sources were read")
        #expect(all.components(separatedBy: "ItemNamespace.isSubsonic(").count - 1 == 0)
        #expect(all.components(separatedBy: "ItemNamespace.isJellyfin(").count - 1 == 0)
        let lyrics = try Self.source("Sources/Views/Music/Lyrics.swift")
        #expect(lyrics.contains("AppSession.shared.musicProvider(for: itemId).lyrics(songId: songId)"))
        #expect(!lyrics.contains("musicProvider(for: songId)"),
                "a bare song id carries no namespace and reached the first server")
    }

    @Test("Warteschlange: die Ansicht holt das Detail ueber die eine Frage und zeigt jeden Eintrag")
    func theQueueViewShowsEveryEntry() throws {
        let view = try Self.source("Sources/Views/PlayQueueView.swift")
        #expect(view.contains("guard SyncCarried.resolvesOnDemand("))
        #expect(!view.contains("guard ItemNamespace.isCatalog(id)"))
        #expect(view.contains("} else if let reason = router.resolve(id, nil).reason {"),
                "an entry that cannot play here says why instead of vanishing")
    }
}
#endif
