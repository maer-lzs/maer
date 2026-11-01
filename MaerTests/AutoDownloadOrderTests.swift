// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "In order" fetches from where the listener is, the settings sheet
/// writes only what changed, and a run says which direction it read.
struct AutoDownloadOrderTests {
    private static func source(_ relative: String) throws -> String {
        try FetchAnswerTests.squeezedSource(relative)
    }

    /// The cases live in `Fixtures/Shared/abos/auto-download-order.json`, read
    /// by Swift and Kotlin alike: the measured case (726 episodes, at 100),
    /// one episode out of the row is not the place, the anchor's gap, and
    /// the edges (no mark, a skipped episode, a download, all heard).
    nonisolated static let order = SharedCases.cases("auto-download-order")

    /// The episodes e1 to eN, pubDate = number, as the file names them.
    private static func episodes(_ value: JSONValue?) -> [PodcastAutoDownloadRules.Candidate] {
        (1...max(1, value?["count"]?.int ?? 1)).map { .init(guid: "e\($0)", pubDate: Double($0)) }
    }

    @Test("gemeinsame Faelle: auto-download-order traegt dreizehn Faelle")
    func orderCasesLoaded() {
        #expect(Self.order.count == 13)
    }

    @Test("gemeinsame Faelle: Der Reihe nach antwortet je Fall wie die Datei sagt", arguments: order)
    func nextInOrder(_ c: SharedCase) throws {
        let input = try c.value("input")
        switch c.ask {
        case "nextInOrder":
            let played = Set(input["played"]?.strings ?? [])
            let started = Set(input["started"]?.strings ?? [])
            let local = Set(input["local"]?.strings ?? [])
            let picked = PodcastAutoDownloadRules.nextInOrder(
                Self.episodes(input["episodes"]), isPlayed: { played.contains($0) },
                isStarted: { started.contains($0) }, isDownloaded: { local.contains($0) },
                limit: try #require(input["limit"]?.int))
            #expect(picked == c["expect"]?.strings, "\(c.slug)")
            for forbidden in c["mustNotContain"]?.strings ?? [] {
                #expect(!picked.contains(forbidden), "\(c.slug): \(forbidden)")
            }
        case "anchorIndex":
            let marked = try #require(input["marked"]?.array).compactMap(\.bool)
            #expect(PodcastAutoDownloadRules.anchorIndex(marked: marked) == c["expect"]?.int, "\(c.slug)")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    @Test("G14-1: angefangen heisst eine halbe Minute, wie bei Weiterhoeren, an der Stelle, die den Lauf baut", .needsTheSources)
    func begunMeansHalfAMinute() throws {
        #expect(PodcastAutoDownloadRules.startedAtLeast == 30)
        #expect(PodcastAutoDownloadRules.runGap == 3)
        #expect(!PodcastAutoDownloadRules.isStarted(.inProgress(fraction: 0.02, remaining: 590), duration: 600))
        #expect(PodcastAutoDownloadRules.isStarted(.inProgress(fraction: 0.05, remaining: 570), duration: 600))
        #expect(!PodcastAutoDownloadRules.isStarted(.played, duration: 600))
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("let wanted = PodcastAutoDownloadRules.wanted(show.episodes, direction: direction, since: since(show.id), state: state)"))
        let rules = try Self.source("Sources/Models/PodcastAutoDownloadRules.swift")
        #expect(rules.contains("isStarted: { guid in byGuid[guid].map { isStarted(state($0), duration: $0.duration) } ?? false }"))
        // A routine's rule asks the same question at the same place, and
        // the half minute is spelled nowhere else.
        let routine = try Self.source("Sources/Providers/RoutinePlayback.swift")
        #expect(routine.contains("isStarted: PodcastAutoDownloadRules.isStarted(mark, duration: episode.duration)"))
        let spelled = ProjectFileIntegrityTests.sourceTexts().filter { file in
            SyncContractFenceTests.stripped(file.text).contains("startedAtLeast")
        }.map(\.name)
        #expect(spelled == ["PodcastAutoDownloadRules.swift"], "the half minute is read at its one place: \(spelled)")
    }

    @Test("Blatt: jedes Feld schreibt nur eine Aenderung, das Oeffnen schreibt nichts", .needsTheSources)
    func theSheetWritesOnlyChanges() throws {
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        for (field, guardLine) in [
            ("rate", "guard new != AppStorageKeys.float(AppStorageKeys.podcastShowRate(showId)) else { return }"),
            ("notify", "guard on != AppStorageKeys.podcastNotifyEnabled(showId) else { return }"),
        ] {
            let change = try #require(sheet.range(of: ".onChange(of: \(field)) {"), "\(field)")
            let check = try #require(sheet.range(of: guardLine), "\(field) has no guard")
            #expect(change.upperBound <= check.lowerBound, "\(field): the guard sits in its own handler")
        }
        // The three values a show can take from all shows write
        // through a binding the hand reaches, never through `onChange`, and
        // only a value the show does not already act on.
        #expect(!sheet.contains(".onChange(of: own"), "filling the sheet would write again")
        let binding = try #require(functionBody(of: "private func ownBinding(", in: sheet))
        let settle = try #require(binding.range(of: "guard raw != field.stored(showId) else { return }"))
        let write = try #require(binding.range(of: "field.setOwn(raw, showId: showId)"))
        #expect(settle.upperBound <= write.lowerBound, "the guard sits before the write")
        let fields = try Self.source("Sources/ViewModels/PodcastGeneralSettings.swift")
        let setOwn = try #require(functionBody(of: "func setOwn(", in: fields))
        #expect(setOwn.contains("guard raw != PodcastGeneralRule.effective(stored: stored(showId), general: general) else { return }"))
    }

    @Test("Messung: der Lauf schreibt je Sendung Richtung, Stichtag und Wahl, und der Bericht nennt den Zustand", .needsTheSources)
    @MainActor
    func theRunSaysWhatItRead() throws {
        let helpers = try Self.source("Sources/Views/Podcasts/PodcastHelpers.swift")
        #expect(helpers.contains("Logger.library.notice(\"AUTODOWNLOAD show=\\(show.id, privacy: .public) direction=\\(direction.rawValue, privacy: .public) keep=\\(keep)"))
        let sheet = try Self.source("Sources/Views/Podcasts/PodcastShowSettingsSheet.swift")
        #expect(sheet.contains("return report + \"\\n\" + PodcastAutoDownload.stateLine(showId, format: format)"))

        let showId = "feed:witness-\(UUID().uuidString)"
        defer {
            AppStorageKeys.remove("podcastAutoDownloadMode.\(showId)")
            AppStorageKeys.remove(PodcastAutoDownload.flagKey(showId))
            AppStorageKeys.remove(PodcastAutoDownload.directionKey(showId))
        }
        // The value of an older build reads as on plus its direction, and
        // the line says where the direction came from.
        AppStorageKeys.set("inOrder", for: "podcastAutoDownloadMode.\(showId)")
        AppStorageKeys.set(true, for: PodcastAutoDownload.flagKey(showId))
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" })
            .contains("on (chosen), direction inOrder (from the older setting)"))
        AppStorageKeys.set("newest", for: PodcastAutoDownload.directionKey(showId))
        #expect(PodcastAutoDownload.stateLine(showId, format: { _ in "t" }).contains("direction newest (chosen)"))
    }

    /// Episodes 1 to 5 of one show, ten minutes each, pubDate = number.
    private static func showEpisodes(key: String) -> [PodcastEpisode] {
        (1...5).map { PodcastEpisode(guid: "rss:\(key):\($0)", title: "Folge \($0)",
                                     audioURL: "https://feeds.example/\($0).mp3",
                                     pubDate: Double($0), duration: 600) }
    }

    @Test("eine Sendung, zwei Urteile, zwei Antworten: lokal ungehoert, geteilt gehoert, in beiden Richtungen")
    func oneShowTwoJudgementsTwoAnswers() {
        let episodes = Self.showEpisodes(key: "k")
        let local: (PodcastEpisode) -> EpisodePlayState = { _ in .unplayed }
        let shared: (PodcastEpisode) -> EpisodePlayState = { $0.guid.hasSuffix(":1") || $0.guid.hasSuffix(":2") ? .played : .unplayed }
        let ids = { (numbers: [Int]) in numbers.map { "rss:k:\($0)" } }
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .inOrder, since: 0, state: local) == ids([1, 2, 3, 4, 5]))
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .inOrder, since: 0, state: shared) == ids([3, 4, 5]))
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .newest, since: 0, state: local) == ids([5, 4, 3, 2, 1]))
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .newest, since: 0, state: shared) == ids([5, 4, 3]))
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .newest, since: 4, state: shared) == ids([5, 4]), "the cutoff still holds")
        #expect(PodcastAutoDownloadRules.protects(.inProgress(fraction: 0.01, remaining: 594)), "any begun state protects")
        #expect(!PodcastAutoDownloadRules.protects(.unplayed))
        #expect(!PodcastAutoDownloadRules.protects(.played))
    }

    /// The other way round: heard here, begun on the server later. The
    /// shared judgement takes the newer state, so the run fetches and keeps
    /// the episode the person is in, where the local one let it go.
    @Test("Gegenrichtung: lokal gehoert, am Server begonnen und neuer, das geteilte Urteil nimmt den neueren Stand")
    @MainActor
    func heardHereBegunOnTheServerLater() throws {
        let key = "witness\(UUID().uuidString.prefix(8))"
        let episodes = Self.showEpisodes(key: key)
        let third = episodes[2]
        let absId = "abspod:\(key):3"
        let now = Date().timeIntervalSince1970 * 1000
        defer {
            ListeningStore.clearBackup(third.guid)
            ABSPodcastProvider.shared.testBridge(rss: third.guid, abs: absId, progress: nil)
        }
        ListeningStore.store(third.guid, entry: [ProgressMark.playedSentinel, now - 3_600_000])
        ABSPodcastProvider.shared.testBridge(rss: third.guid, abs: absId,
                                             progress: BookProgress(fraction: 0.5, isFinished: false, lastUpdate: now, currentTime: 300))
        let item = podcastLibraryItem(show: PodcastShow(id: "feed:\(key)", title: "Morgen", author: nil, artworkURL: nil,
                                                        description: nil, feedURL: "https://feeds.example/\(key).xml",
                                                        episodes: episodes),
                                      episode: third)
        let localThird = PodcastProgressStore.shared.state(guid: third.guid, duration: third.duration)
        let sharedThird = podcastPlayState(for: item)
        #expect(localThird == .played, "the precondition: heard on this device")
        guard case .inProgress = sharedThird else {
            Issue.record("the shared judgement takes the newer server state, said \(sharedThird)")
            return
        }
        let local: (PodcastEpisode) -> EpisodePlayState = { $0.guid == third.guid ? localThird : .unplayed }
        let shared: (PodcastEpisode) -> EpisodePlayState = { $0.guid == third.guid ? sharedThird : .unplayed }
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .inOrder, since: 0, state: local) == [episodes[3].guid, episodes[4].guid])
        #expect(PodcastAutoDownloadRules.wanted(episodes, direction: .inOrder, since: 0, state: shared) == [third.guid, episodes[3].guid, episodes[4].guid])
        #expect(PodcastAutoDownloadRules.protects(sharedThird), "the run keeps its own download of it")
        #expect(!PodcastAutoDownloadRules.protects(localThird))
    }

    @Test("der Lauf fragt das geteilte Urteil einmal je Folge, das Aufraeumen bleibt lokal", .needsTheSources)
    func theRunAsksTheSharedJudgementOnce() throws {
        let helpers = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastHelpers.swift"), encoding: .utf8))
        let run = try #require(functionBody(of: "static func run(shows: [PodcastShow], router: ItemRouter = .live) async {", in: helpers))
        #expect(!run.contains("progress.state(") && !run.contains("PodcastProgressStore"), "no local question left in the run")
        #expect(run.components(separatedBy: "podcastPlayState(for:").count - 1 == 1, "one judgement per episode, built once")
        #expect(run.contains("PodcastAutoDownloadRules.protects(state($0.episode))"))
        let sweep = try #require(functionBody(of: "static func sweep(now: Double = Date().timeIntervalSince1970) {", in: helpers))
        #expect(sweep.contains("ListeningStore.backup(id)") && !sweep.contains("podcastPlayState"), "the clean-up keeps the local mark and its time")
    }
}
#endif
