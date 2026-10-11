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
    }

    @Test("die Region ist gescheitert, wenn jede Namensvariante scheiterte; ein leerer Erfolg ist keiner, eine einzelne Antwort reicht")
    func aRegionFailsOnlyWhenEveryVariantFailed() {
        #expect(!RadioStore.regionFailed(variantAnswered: []), "no variant asked counts as failed")
        #expect(RadioStore.regionFailed(variantAnswered: [false]))
        #expect(RadioStore.regionFailed(variantAnswered: [false, false, false]))
        #expect(!RadioStore.regionFailed(variantAnswered: [false, true]), "one answer was not enough")
        #expect(!RadioStore.regionFailed(variantAnswered: [true]))
    }
}
#endif
