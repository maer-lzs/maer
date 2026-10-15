// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import OSLog
@testable import Maer

/// A failed fetch is not an empty answer (`FetchAnswer`), and the surfaces
/// that read `(try? fetch()) ?? []` ask through it now.
@MainActor
struct FetchAnswerTests {
    private static let logger = Logger(subsystem: "fm.maer.app.tests", category: "fetch-answer")

    @Test("ein Abruf hat drei Antworten: Wert, Fehler mit Grund, Abbruch ist kein Fehler")
    func threeAnswers() async throws {
        let value = await FetchAnswer.of("probe", logger: Self.logger) { [1, 2] }
        #expect(value.value == [1, 2])
        #expect(!value.failed)

        let failed = await FetchAnswer<[Int]>.of("probe", logger: Self.logger) { throw URLError(.timedOut) }
        guard case .failed(let reason) = failed else {
            Issue.record("a thrown error is not a failure: \(failed)")
            return
        }
        #expect(reason == "urlError=\(URLError.Code.timedOut.rawValue)")
        #expect(failed.value == nil)
        #expect(throws: FetchAnswer<[Int]>.Failure.self) { try failed.get() }

        let cancelled = await FetchAnswer<[Int]>.of("probe", logger: Self.logger) { throw CancellationError() }
        #expect(!cancelled.failed, "a cancellation was booked as a failure")
        let urlCancelled = FetchAnswer<[Int]>.from(URLError(.cancelled))
        #expect(!urlCancelled.failed)
        #expect(throws: CancellationError.self) { try cancelled.get() }
    }

    @Test("mehrere Abrufe einer Liste: gescheitert nur, wenn keiner antwortete")
    func joinedFailsOnlyWhenNoneAnswered() {
        let some = FetchAnswer.joined([.value([1]), .failed(reason: "a"), .value([2, 3])])
        #expect(some.value == [1, 2, 3], "an answer beside a failure was dropped")

        let none = FetchAnswer<[Int]>.joined([.failed(reason: "a"), .cancelled])
        #expect(none.failed, "no answer and a failure is not a failure")

        let emptyAnswer = FetchAnswer<[Int]>.joined([.value([]), .failed(reason: "a")])
        #expect(emptyAnswer.value == [], "an empty answer is an answer")

        let allCancelled = FetchAnswer<[Int]>.joined([.cancelled, .cancelled])
        #expect(!allCancelled.failed && allCancelled.value == nil)

        #expect(FetchAnswer<[Int]>.joined([]).value == [])
    }

    /// The fetches that read `(try? …) ?? []` and showed a failure as an
    /// empty list. Each is asked through `FetchAnswer` now; the old form
    /// must not come back.
    nonisolated static let silentFetches: [(file: String, old: String)] = [
        ("Sources/Views/PodcastSourceView.swift", "try? await directory.search("),
        ("Sources/Views/PodcastsView.swift", "try? await directory.topPodcasts("),
        ("Sources/Views/Music/MusicBrowseViews.swift", "try? await music.artistAlbums("),
        ("Sources/Views/Radio/RadioView.swift", "try? await RadioBrowserClient.states("),
        ("Sources/Views/Music/AddToPlaylistSheet.swift", "try? await AppSession.shared.musicProvider(serving: .one(server)).allPlaylists("),
        ("Sources/Views/Music/MusicViewModel.swift", "try? await source.albumsPage("),
        ("Sources/Views/SubsonicSourceView.swift", "try? await SubsonicProvider.shared.refreshLibraries("),
        ("Sources/Views/ABSSourceView.swift", "try? await coordinator.provider.fetchLibraries("),
        ("Sources/Providers/RadioProvider.swift", "try? await RadioBrowserClient.search("),
        ("Sources/ViewModels/GlobalSearchModel.swift", "try? await LibriVoxClient.searchBooks("),
        ("Sources/ViewModels/GlobalSearchModel.swift", "try? await GutenbergClient.audiobooks("),
        ("Sources/ViewModels/GlobalSearchModel.swift", "try? await ArchiveOrgClient.popular("),
        ("Sources/CarPlay/CarPlaySceneDelegate.swift", "try? await AppSession.shared.musicProvider.albumShelf("),
        ("Sources/CarPlay/CarPlaySceneDelegate.swift", "try? await AppSession.shared.musicProvider.fetchLibraryItems("),
    ]

    nonisolated static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    @Test("die Abrufe, die einen Fehler als leere Liste zeigten, fragen ueber FetchAnswer", .needsTheSources)
    func theSilentFetchesAskThroughTheAnswer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for site in Self.silentFetches {
            let text = Self.squeezed(try String(contentsOf: root.appendingPathComponent(site.file), encoding: .utf8))
            if text.contains(site.old) || !text.contains("FetchAnswer") {
                offenders.append("\(site.file): \(site.old)")
            }
        }
        #expect(offenders.isEmpty, "a fetch shows its failure as an empty list again: \(offenders)")
        // The finder sees the old form, squeezed over a line break.
        #expect(Self.squeezed("let x = (try? await\n    directory.search(term)) ?? []").contains("try? await directory.search("))
    }
}
#endif
