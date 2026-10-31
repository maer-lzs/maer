// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A routine at its start: each rule becomes what it picks, judged with the
/// shared state and the auto-download's half minute, and no rule reaches
/// the queue or the context.
@MainActor
@Suite(.serialized)
struct RoutinePlaybackTests {
    private static let feedURL = "https://feeds.example/routine.xml"
    private static var key: String { PodcastSubscriptions.feedKey(feedURL) }

    /// Episodes 1 to `count`, ten minutes each, `silent` without audio.
    private static func show(_ count: Int, silent: Set<Int> = []) -> PodcastShow {
        PodcastShow(id: "feed:\(key)", title: "Morgen", author: nil, artworkURL: nil,
                    description: nil, feedURL: feedURL,
                    episodes: (1...count).map {
                        PodcastEpisode(guid: "rss:\(key):\($0)", title: "Folge \($0)",
                                       audioURL: silent.contains($0) ? "" : "https://feeds.example/\($0).mp3",
                                       pubDate: Double($0) * 1000, duration: 600)
                    })
    }

    private static func id(_ number: Int) -> String { "rss:\(key):\(number)" }

    private static func item(_ id: String) -> LibraryItem { LibraryItem(id: id, media: nil, addedAt: nil) }

    private static func picks(_ rule: RoutineRule, in show: PodcastShow? = show(5), online: Bool = true,
                              downloaded: Set<String> = [],
                              state: (LibraryItem) -> EpisodePlayState = { _ in .unplayed }) -> [String] {
        RoutinePlayback.picks(rule, in: show, online: online, state: state,
                              isDownloaded: { downloaded.contains($0) }).map(\.id)
    }

    @Test("eine Liste ohne Regeln startet wie bisher: jeder Eintrag, den das Geraet aufloest, in Reihenfolge, der erste von vorn")
    func aListWithoutRulesStartsAsBefore() {
        let start = RoutinePlayback.expand(["a", "gone", "b"], entry: { $0 == "gone" ? nil : Self.item($0) },
                                           picks: { _ in Issue.record("no rule here"); return [] })
        #expect(start.items.map(\.id) == ["a", "b"])
        #expect(!start.firstFromRule)
    }

    @Test("eine Regel wird an ihrem Platz zu ihren Folgen, jede Folge laeuft einmal, und nur eine Folge einer Regel an erster Stelle setzt fort")
    func aRuleBecomesItsEpisodesInPlace() throws {
        let newest = try #require(RoutineRule(id: "rule:newest:aaaa"))
        let next = try #require(RoutineRule(id: "rule:next:2:bbbb"))
        let picked: (RoutineRule) -> [LibraryItem] = { rule in
            rule == newest ? [Self.item("n1")] : [Self.item("x"), Self.item("b2")]
        }
        let start = RoutinePlayback.expand([newest.id, "x", next.id], entry: { Self.item($0) }, picks: picked)
        #expect(start.items.map(\.id) == ["n1", "x", "b2"], "x plays once, where the list first names it")
        #expect(start.firstFromRule)

        let silentFirst = RoutinePlayback.expand([newest.id, "x"], entry: { Self.item($0) }, picks: { _ in [] })
        #expect(silentFirst.items.map(\.id) == ["x"])
        #expect(!silentFirst.firstFromRule, "a rule that picks nothing leaves the first place to the title")
    }

    @Test("dieselbe Liste, lokal ungehoert und geteilt gehoert: die Routine nimmt die naechste nach dem geteilten Urteil")
    func theSharedJudgementDecides() throws {
        let next = try #require(RoutineRule(kind: .next(count: 1), feedKey: Self.key))
        let local: (LibraryItem) -> EpisodePlayState = { _ in .unplayed }
        let shared: (LibraryItem) -> EpisodePlayState = { $0.id == Self.id(1) || $0.id == Self.id(2) ? .played : .unplayed }
        #expect(Self.picks(next, state: local) == [Self.id(1)])
        #expect(Self.picks(next, state: shared) == [Self.id(3)])

        // The live judgement is the shared one: a mark only in the
        // listening store, read through `podcastPlayState`, moves the rule.
        defer { ListeningStore.clearBackup(Self.id(1)) }
        ListeningStore.store(Self.id(1), entry: [ProgressMark.playedSentinel, Date().timeIntervalSince1970])
        #expect(Self.picks(next, state: { podcastPlayState(for: $0) }) == [Self.id(2)])
    }

    @Test("begonnen ist eine halbe Minute wie beim Auto-Download: zehn Sekunden sind nicht der Stand, vierzig schon, und eine begonnene neueste setzt fort")
    func begunIsTheAutoDownloadsHalfMinute() throws {
        let next = try #require(RoutineRule(kind: .next(count: 1), feedKey: Self.key))
        let tasted: (LibraryItem) -> EpisodePlayState = { $0.id == Self.id(3) ? .inProgress(fraction: 0.02, remaining: 590) : .unplayed }
        let begun: (LibraryItem) -> EpisodePlayState = { $0.id == Self.id(3) ? .inProgress(fraction: 0.07, remaining: 560) : .unplayed }
        #expect(Self.picks(next, state: tasted) == [Self.id(1)], "ten seconds of episode 3 are no place")
        #expect(Self.picks(next, state: begun) == [Self.id(3)], "forty seconds are")

        let newest = try #require(RoutineRule(kind: .newest, feedKey: Self.key))
        let newestBegun: (LibraryItem) -> EpisodePlayState = { $0.id == Self.id(5) ? .inProgress(fraction: 0.5, remaining: 300) : .unplayed }
        #expect(Self.picks(newest, state: newestBegun) == [Self.id(5)])
        let start = RoutinePlayback.expand([newest.id], entry: { _ in nil }) { rule in
            RoutinePlayback.picks(rule, in: Self.show(5), online: true, state: newestBegun, isDownloaded: { _ in false })
        }
        #expect(start.firstFromRule, "so the start resumes it")
    }

    @Test("eine Sendung, die das Geraet nicht kennt, und eine Folge ohne Ton waehlt keine Regel; ohne Netz nur Geladenes")
    func unknownShowsSilentEpisodesAndOffline() throws {
        let newest = try #require(RoutineRule(kind: .newest, feedKey: Self.key))
        #expect(Self.picks(newest, in: nil).isEmpty)
        #expect(Self.picks(newest, in: Self.show(5, silent: [5])) == [Self.id(4)], "the newest with audio")
        #expect(Self.picks(newest, online: false).isEmpty)
        #expect(Self.picks(newest, online: false, downloaded: [Self.id(5)]) == [Self.id(5)])
        #expect(RoutinePlayback.show(feedKey: "no-such-show") == nil)
    }

    @Test("keine Regel erreicht die Bestellungen oder den Kontext, eine Liste haelt sie weiter")
    func noRuleReachesTheQueueOrTheContext() {
        let rule = "rule:newest:aaaa"
        #expect(PlayQueue.canEnqueue(rule), "a list keeps its rules")
        #expect(!PlayQueue.canHold(rule))
        #expect(!PlayQueue.canHold("radio:rb:x"))
        #expect(PlayQueue.canHold("rss:a:1"))

        let queue = PlayQueue(persists: false, equivalents: { [$0] })
        queue.playNext(rule)
        queue.playLast(rule)
        #expect(queue.isEmpty)
        let context = PlaybackContext()
        context.replace(ids: ["rss:a:1", rule, "rss:a:2"], source: "Morgens")
        #expect(context.ids == ["rss:a:1", "rss:a:2"])
        #expect(context.expand("rss:a:2", into: [rule, "rss:a:3"]))
        #expect(context.ids == ["rss:a:1", "rss:a:3"])
    }

    /// Both play buttons of a list start through the one door, and the door
    /// hands the first place's resume to `playInOrder`.
    @Test("beide Abspielknoepfe einer Liste starten durch RoutinePlayback.start, und der Start reicht das Fortsetzen weiter", .needsTheSources)
    func bothButtonsStartThroughTheOneDoor() throws {
        var starts: [String: Int] = [:]
        var bare: [String] = []
        for file in ProjectFileIntegrityTests.sourceTexts() {
            let code = SyncContractFenceTests.stripped(file.text)
            let count = code.components(separatedBy: "RoutinePlayback.start(").count - 1
            if count > 0 { starts[file.name] = count }
            if !["RoutineRule.swift", "RoutinePlayback.swift"].contains(file.name), code.contains("RoutineRule(id:") || code.contains("RoutineRule.init(id:") {
                bare.append(file.name)
            }
        }
        #expect(starts == ["PlaylistCard.swift": 1, "MusicLibraryPages.swift": 1])
        #expect(bare.isEmpty, "a rule is read for playback in one place: \(bare)")
        let door = try FetchAnswerTests.squeezedSource("Sources/Providers/RoutinePlayback.swift")
        #expect(door.contains("restartFirst: !start.firstFromRule"))
    }
}
#endif
