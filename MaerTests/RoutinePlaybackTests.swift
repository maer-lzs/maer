// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
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

    @Test("das Abbild einer Regel traegt Titel und Bild der Sendung, kein Satz, und kein Bild mit Zugang")
    func aRuleTravelsWithTitleAndPublicPictureOnly() throws {
        let id = try #require(RoutineRule(kind: .next(count: 2), feedKey: Self.key)).id
        var show = Self.show(1)
        show.artworkURL = "https://cdn.example/cover.jpg"
        let plain = try #require(RoutinePlayback.snapshot(id, show: show, premium: false))
        #expect(plain.title == "Morgen")
        #expect(plain.subtitle == nil, "the rule in words is said by the reading device")
        #expect(plain.coverURL == "https://cdn.example/cover.jpg")
        #expect(plain.source == "rule:")
        #expect(RoutinePlayback.snapshot(id, show: show, premium: true)?.coverURL == nil, "a premium feed's picture stays home")
        show.artworkURL = "https://cdn.example/cover.jpg?token=abc"
        #expect(RoutinePlayback.snapshot(id, show: show, premium: false)?.coverURL == nil, "a picture with a secret stays home")
        show.title = id
        #expect(RoutinePlayback.snapshot(id, show: show, premium: false) == nil, "no title, no snapshot")
        #expect(AppSession.shared.carried(forId: "rule:newest:no-such-show") == nil)
        #expect(AppSession.shared.coverURL(forItemId: "rule:newest:no-such-show") == nil)
    }

    /// Each source the answer reads moves it: the listening state, the
    /// downloads, the network, the show's episodes after a fetch.
    @Test("jede Quelle der Antwort bewegt die Zeile: Hoerstand, Downloads, Netz, neue Folgen")
    func everySourceMovesTheLine() throws {
        let newest = try #require(RoutineRule(kind: .newest, feedKey: Self.key))
        let answer: (PodcastShow, Bool, (LibraryItem) -> EpisodePlayState, Set<String>) -> [String] = { show, online, state, local in
            RoutinePlayback.answer(newest, in: show, online: online, state: state,
                                   isDownloaded: { local.contains($0) }).items.map(\.id)
        }
        let unheard: (LibraryItem) -> EpisodePlayState = { _ in .unplayed }
        #expect(answer(Self.show(5), true, unheard, []) == [Self.id(5)])
        #expect(answer(Self.show(6), true, unheard, []) == [Self.id(6)], "a fetch brought episode 6")
        #expect(answer(Self.show(5), true, { $0.id == Self.id(5) ? .played : .unplayed }, []).isEmpty, "heard elsewhere")
        #expect(answer(Self.show(5), false, unheard, []).isEmpty, "offline")
        #expect(answer(Self.show(5), false, unheard, [Self.id(5)]) == [Self.id(5)], "downloaded")
        guard case .showUnknown = RoutinePlayback.answer(newest, in: nil, online: true, state: unheard, isDownloaded: { _ in false }) else {
            Issue.record("an unknown show answers as unknown"); return
        }
    }

    /// The page shows the answer of the moment: it observes each source the
    /// answer reads, holds it once per pass, and every source tells.
    @Test("die Seite einer Liste beobachtet jede Quelle der Antwort, und jede Quelle meldet sich", .needsTheSources)
    func thePageObservesEverySource() throws {
        let pages = try FetchAnswerTests.squeezedSource("Sources/Views/Music/MusicLibraryPages.swift")
        let page = try #require(pages.range(of: "struct MaerPlaylistPage: View {")).upperBound
        let body = String(pages[page...].prefix(4000))
        #expect(body.contains("@ObservedObject private var store = MaerPlaylists.shared"))
        #expect(body.contains("@ObservedObject private var answerSources = RoutineAnswerSources.shared"))
        #expect(body.components(separatedBy: "RoutinePlayback.held(").count == 2, "held once per pass")
        #expect(body.contains("if let line = held?.lines[id] { RoutineRuleRow(line: line,"), "a rule shows its line")

        // Each source reaches the one object the page observes.
        final class Counter { var changes = 0 }
        let counter = Counter()
        let watching = RoutineAnswerSources.shared.objectWillChange.sink { counter.changes += 1 }
        ListeningRevision.shared.bump("routine witness")
        #expect(counter.changes == 1, "the listening state")
        DownloadManager.shared.stock.objectWillChange.send()
        #expect(counter.changes == 2, "the downloads")
        NetworkMonitor.shared.objectWillChange.send()
        #expect(counter.changes == 3, "the network")
        withExtendedLifetime(watching) {}
        // Marks adopted from another device and new episodes both move the
        // listening revision the page observes.
        let state = try FetchAnswerTests.squeezedSource("Sources/Views/Podcasts/PodcastPlayState.swift")
        #expect(state.contains("ListeningRevision.shared.bump(\"podcast store reload\")"))
        let subscriptions = try FetchAnswerTests.squeezedSource("Sources/Providers/PodcastSubscriptions.swift")
        #expect(subscriptions.contains("ListeningRevision.shared.bump(\"subscriptions\")"))
    }

    @Test("die Regel in Worten sagt das lesende Geraet, aus der Art in der Kennung")
    func theDeviceSaysTheRule() throws {
        #expect(RoutineWords.rule(.newest) == String(localized: "Newest episode"))
        #expect(RoutineWords.rule(.next(count: 1)) == String(localized: "Next episode"))
        #expect(RoutineWords.rule(.next(count: 3)) == String(localized: "Next \(3) episodes"))
        #expect(RoutineWords.answer(.absent(.nothingNext)) == String(localized: "No unheard episode from where you stand"))
        #expect(RoutineWords.answer(.showUnknown) == String(localized: "Unknown on this device: follow the show so the routine finds it"))
        let show = Self.show(2)
        let picked = show.episodes.map { podcastLibraryItem(show: show, episode: $0) }
        #expect(RoutineWords.answer(.play(picked)) == [picked[0].title, picked[1].title].formatted(.list(type: .and)))
        #expect(picked[0].title == "Folge 1", "the precondition: an episode names itself")
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

    // MARK: - Adding

    /// A list of its own over a database of its own.
    private static func freshStore() -> MaerPlaylists {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routines-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
    }

    @Test("eine Liste nimmt je Sendung eine Regel, auch unter mehreren, und der Satz nennt die Liste")
    func aListTakesOneRulePerShow() {
        let store = Self.freshStore()
        let list = store.create(name: "Morgens")
        #expect(store.add(itemId: "rule:newest:aaaa", to: list.id) == .added)
        #expect(store.add(itemId: "rule:next:aaaa", to: list.id) == .showHasRule)
        #expect(store.add(itemId: "rule:newest:aaaa", to: list.id) == .showHasRule)
        #expect(store.add(itemId: "rule:next:2:bbbb", to: list.id) == .added)
        #expect(store.add(itemIds: ["jam:1886432", "rule:next:3:bbbb"], to: list.id) == .showHasRule)
        #expect(store.playlists.first { $0.id == list.id }?.itemIds
                == ["rule:newest:aaaa", "rule:next:2:bbbb", "jam:1886432"])
        #expect(PlaylistPresenter.text(for: .showHasRule, listName: "Morgens")?.contains("Morgens") == true)
        store.delete(playlistId: list.id)
    }

    @Test("eine Regel geht nur in eine Liste des Geraets und bleibt eine Kennung")
    func aRuleGoesOnlyToTheDevice() {
        let id = "rule:next:2:aaaa"
        #expect(MusicSourceRule.owner(id) == nil)
        #expect(PlaylistDestination.servers(active: [.jellyfin, .subsonic], owners: [MusicSourceRule.owner(id)]).isEmpty)
        #expect(PlaylistDestination.places(servers: []) == [.device])
        #expect(PlaylistDestination.expansion(for: id, serverKind: nil) == .asIs)
    }

    @Test("nach dem Hinzufuegen fragt das Angebot nur fuer eine gefolgte Sendung ohne Auto-Download")
    func theOfferAsksOnlyWhenOff() {
        let show = Self.show(1)
        let followed: (String) -> PodcastShow? = { $0 == Self.key ? show : nil }
        let rule = "rule:newest:\(Self.key)"
        #expect(RoutinePlayback.autoDownloadOffer(for: [rule], followedShow: followed, isEnabled: { _ in false })?.id == show.id)
        #expect(RoutinePlayback.autoDownloadOffer(for: [rule], followedShow: followed, isEnabled: { _ in true }) == nil)
        #expect(RoutinePlayback.autoDownloadOffer(for: ["rule:newest:zzzz"], followedShow: followed, isEnabled: { _ in false }) == nil,
                "a show not followed here is offered nothing")
        #expect(RoutinePlayback.autoDownloadOffer(for: [Self.id(1)], followedShow: followed, isEnabled: { _ in false }) == nil,
                "an episode is no rule")
    }

    /// The show page offers the rules of a followed feed through the one
    /// playlist action, the offer follows a successful add only, and only
    /// its button switches the downloads on.
    @Test("die Seite einer gefolgten Sendung bietet die Regeln ueber die eine Aktion an, und nur die Antwort schaltet den Auto-Download", .needsTheSources)
    func theShowPageOffersTheRules() throws {
        let page = try FetchAnswerTests.squeezedSource("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(page.contains("private var routineShow: PodcastShow? { isServerShow ? nil : storedShow }"))
        #expect(page.contains("if let show = routineShow { Menu { ForEach(RoutineRule.offered(feedKey:"))
        #expect(page.contains("AddToPlaylistButton(itemId: rule.id, knownTitles: [rule.id: show.title], label: RoutineWords.rule(rule.kind))"))
        let sheet = try FetchAnswerTests.squeezedSource("Sources/Views/Music/AddToPlaylistSheet.swift")
        #expect(sheet.contains("if outcome == .added { offeringAutoDownload = RoutinePlayback.autoDownloadOffer(for: expanded.ids) }"))
        var switching: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceTexts() {
            let count = SyncContractFenceTests.stripped(file.text).components(separatedBy: "PodcastAutoDownload.setEnabled(").count - 1
            if count > 0 { switching[file.name] = count }
        }
        #expect(switching == ["PodcastGeneralSettings.swift": 1, "AddToPlaylistSheet.swift": 1])
        #expect(sheet.contains("Button(\"Download Automatically\") { PodcastAutoDownload.setEnabled(show.id, true) }"))
    }
}
#endif
