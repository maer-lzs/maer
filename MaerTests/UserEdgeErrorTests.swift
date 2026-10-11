// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// At the edge where a person acts, an error has its line and a visible
/// action an outcome; a tap that is turned away changes nothing.
struct UserEdgeErrorTests {
    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    /// A tap offline on a title that is not downloaded is turned away
    /// before it touches the lists: the context stays and the title stays
    /// in Up Next. Only the shortcut for the title already open takes the
    /// lists over before that check, because it does play.
    @Test("ein abgewiesener Tipp laesst Kontext und Up Next stehen: die Listen werden erst nach der Offline-Abweisung uebernommen", .needsTheSources)
    func aRefusedTapLeavesTheLists() throws {
        let coordinator = try code("Sources/ViewModels/PlayerCoordinator.swift")
        let open = try #require(coordinator.range(of: "func open(item: LibraryItem"), "the open is gone")
        let refusal = try #require(coordinator.range(of: "MediaAvailability.offlineUnavailable(", range: open.upperBound..<coordinator.endIndex),
                                   "the offline refusal is gone")
        let before = String(coordinator[open.upperBound..<refusal.lowerBound])
        #expect(!before.contains("PlaybackContext.shared.clear()") && !before.contains("leaveBothLists("),
                "the lists are touched before the refusal")
        let shortcut = try #require(before.range(of: "activeItem?.id == item.id"), "the shortcut is gone")
        #expect(before.components(separatedBy: "takeOver(item.id").count == 2
                && before[shortcut.upperBound...].contains("takeOver(item.id"),
                "a take over stands before the refusal outside the shortcut")
        // After the shortcut the lists are taken over at ONE point: in
        // `start`, behind the check that the open is still the current one.
        #expect(coordinator.components(separatedBy: "takeOver(item.id").count == 3, "a take over stands outside the shortcut and the start")
        let start = try #require(coordinator.range(of: "private func start(detail:"), "the start is gone")
        let body = coordinator[start.upperBound...].prefix(2500)
        let guardLine = try #require(body.range(of: "guard generation == openGeneration else { newViewModel.stop(); return }"))
        let take = try #require(body.range(of: "takeOver(item.id, preservesContext: preservesContext)"), "the start does not take the lists over")
        #expect(guardLine.upperBound <= take.lowerBound, "the start takes the lists over before it knows the open stands")
    }

    /// The real open, online, of a title whose detail cannot be fetched and
    /// that has no stored detail: it ends in the sentence, and the context
    /// and Up Next stand as they were. The late refusal, after the offline
    /// check, used to empty the context and take the title out of Up Next.
    @MainActor
    @Test("ein Oeffnen, dessen Detail nicht kommt, laesst Kontext und Up Next stehen")
    func aFailedFetchLeavesTheLists() async {
        let id = "jf:album:w4010-\(UUID().uuidString)"
        let other = "jf:album:w4010-other-\(UUID().uuidString)"
        let context = PlaybackContext.shared
        let before = (ids: context.ids, title: context.sourceTitle)
        defer {
            context.replace(ids: before.ids, source: before.title)
            PlayQueue.shared.remove(id)
        }
        context.replace(ids: [other, id], source: "witness")
        PlayQueue.shared.playLast(id)
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)
        await Reachability.$assumed.withValue(true) {
            await coordinator.open(item: LibraryItem(id: id, media: media, addedAt: nil))
        }
        #expect(coordinator.viewModel == nil && coordinator.loadError != nil, "the precondition: the open failed at the fetch")
        #expect(PlayQueue.shared.contains(id), "a failed open took the title out of Up Next")
        #expect(context.ids == [other, id], "a failed open changed the context: \(context.ids)")
    }

    /// The silent spots of the order: each now has its line, and the visible
    /// ones an outcome.
    @Test("die stillen Stellen an der Nutzerkante haben ihre Zeile und ihren Ausgang", .needsTheSources)
    func theSilentSpotsSpeak() throws {
        let sync = try code("Sources/ViewModels/PlayerViewModel+Sync.swift")
        let reconcile = try #require(sync.range(of: "func reconcileWithServer()"), "the reconcile is gone")
        #expect(sync[reconcile.upperBound...].contains("RECONCILE item=") && sync[reconcile.upperBound...].contains("failed reason="),
                "the reconcile swallows its error")
        let book = try code("Sources/Views/BookDetailScreen.swift")
        #expect(!book.contains("try? await detailProvider.fetchItemDetail"), "the book page swallows a failed detail")
        #expect(book.contains("LoadFailedView(form: .line) { Task { await loadDetail() } }"), "the book page offers no retry")
        let player = try code("Sources/Views/PlayerView.swift")
        #expect(!player.contains("(try? await AppSession.shared.musicProvider(for: id).allArtists())"), "Go to Artist swallows a failed list")
        #expect(player.components(separatedBy: "coordinator.sayOpenFailure(").count == 3, "Go to Artist does not say both failures")
        #expect(player.contains("String(localized: \"Artist not found on this server.\")"),
                "an unknown artist name does not say its own sentence")
        let show = try code("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(!show.contains("_ = await absPodcast.deleteShowOnServer"), "the delete drops its answer")
        #expect(show.contains("deleteError = ErrorSentence.of(error)"), "a refused delete does not say why")
        let radio = try code("Sources/Views/Radio/RadioView.swift")
        #expect(radio.contains("RadioStore.discoveryStep(failed: regionFailed, standing: !regional.isEmpty)"),
                "the region does not go through the discovery step")
        #expect(radio.contains("discoveryLoaded = regionStep == .replace"), "a failed region counts as loaded")
        #expect(radio.contains("if regionalFailed {"), "the region section has no failed state")
        // Each region list keeps the reason it failed for the log line.
        #expect(!radio.contains("try? await RadioBrowserClient.byState"), "a region list swallows its reason")
        #expect(radio.contains("RadioRegionList.fetch { try await RadioBrowserClient.byState(state: name) }")
                && radio.contains("RadioRegionList.fetch { try await RadioBrowserClient.byStateClicktrend(state: name) }"),
                "a region list is fetched past the one that keeps its reason")
        #expect(radio.contains("votes=\\(v.logged, privacy: .public) trend=\\(c.logged, privacy: .public)"),
                "the log line of a variant does not carry the reason")
    }

    /// The part of a region list in the log line: a failure names its
    /// reason, an answer its count (an empty answer is an answer).
    @Test("eine gescheiterte Liste der Region sagt in der Logzeile failed mit ihrem Grund, eine beantwortete ihre Zahl")
    func aRegionListLogsItsReason() async {
        let failure = URLError(.timedOut)
        let failed = await RadioRegionList.fetch { throw failure }
        #expect(failed.stations == nil)
        #expect(failed.logged == "failed(\(FailureReason.of(failure)))", "the log line lost the reason: \(failed.logged)")
        let station = RadioStation(id: "radio:manual:probe", name: "Probe", streamURL: "https://probe.example/stream")
        let answered = await RadioRegionList.fetch { [station, station] }
        #expect(answered.logged == "2")
        let empty = await RadioRegionList.fetch { [] }
        #expect(empty.logged == "0", "an empty answer reads as a failure")
    }

    /// A handed sentence is said by the one alert (`sentenceAlert`), not by
    /// a hand-built alert beside it.
    @Test("ein uebergebener Satz kommt ueber die eine Meldung, keine von Hand gebaute daneben", .needsTheSources)
    func aSentenceIsSaidByTheOneAlert() throws {
        var handBuilt: [String] = []
        var users = 0
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "ActionFailedAlert.swift" {
            let squeezed = StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
            if squeezed.range(of: #"\.alert\(Text\((verbatim:)?\w+\?\?""\),isPresented:Binding\("#, options: .regularExpression) != nil {
                handBuilt.append(name)
            }
            users += squeezed.components(separatedBy: ".sentenceAlert($").count - 1
        }
        #expect(handBuilt.isEmpty, "a sentence alert is built by hand: \(handBuilt)")
        #expect(users == 3, "the surfaces that say a handed sentence are not the three measured: \(users)")
        #expect(StockDriftTests.squeezed(SyncContractFenceTests.stripped(try code("Sources/Views/Podcasts/PodcastShowView.swift"))).contains(".sentenceAlert($deleteError)"))
    }

    @Test("die Region ist gescheitert, wenn jede Namensvariante scheiterte; ein leerer Erfolg ist keiner, eine einzelne Antwort reicht")
    func aRegionFailsOnlyWhenEveryVariantFailed() {
        #expect(!RadioStore.regionFailed(variantAnswered: []), "no variant asked counts as failed")
        #expect(RadioStore.regionFailed(variantAnswered: [false]))
        #expect(RadioStore.regionFailed(variantAnswered: [false, false, false]))
        #expect(!RadioStore.regionFailed(variantAnswered: [false, true]), "one answer was not enough")
        #expect(!RadioStore.regionFailed(variantAnswered: [true]))
    }

    /// In a list section the failure reads like the empty text beside it
    /// ("No playlists yet."): body size, leading, Retry at the end. The small
    /// centred line stays for the places below rows already read.
    @Test("in einem Listen-Abschnitt steht ein Ladefehler in der Form der Leerzeile daneben, nicht als kleine Zeile in der Mitte", .needsTheSources)
    func aFailureInAListReadsLikeItsEmptyText() throws {
        let view = try code("Sources/Views/LoadFailedView.swift")
        let row = try #require(view.range(of: "case .row:"), "the failure has no row form")
        let rowBody = view[row.upperBound...]
        #expect(rowBody.contains(".frame(maxWidth: .infinity, alignment: .leading)"), "the row is not leading")
        #expect(!rowBody.contains(".font(.footnote)"), "the row is smaller than the empty text beside it")
        let users = ["Sources/Views/Music/AddToPlaylistSheet.swift": "LoadFailedView(form: .row, sentence: \"Playlists could not be loaded.\")",
                     "Sources/Views/PodcastSourceView.swift": "LoadFailedView(form: .row) {",
                     "Sources/Views/ABSSourceView.swift": "LoadFailedView(form: .row) { Task { await loadLibraries() } }"]
        for (path, call) in users {
            let source = try code(path)
            #expect(source.contains(call), "\(path) shows its failure in another form than its empty text")
            #expect(!source.contains("LoadFailedView(form: .line"), "\(path) still has a small centred line in a list")
        }
    }
}
#endif
