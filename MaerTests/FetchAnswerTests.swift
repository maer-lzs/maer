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

    /// Comment lines out, every run of whitespace one space: the form the
    /// source fences read code in. The one copy for the whole test target.
    nonisolated static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A file below the repository root, read and squeezed.
    nonisolated static func squeezedSource(_ relative: String) throws -> String {
        squeezed(try String(contentsOf: SourceTree.root.appendingPathComponent(relative), encoding: .utf8))
    }

    /// How many copies of `squeezed` a text spells out: comments stripped,
    /// then whitespace split and joined by one space, in one expression.
    /// Read without any whitespace, so a copy spread over lines or spaced
    /// otherwise is the same finding.
    nonisolated static func squeezeCopies(in text: String) -> Int {
        let flat = StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
        let copy = #"stripped\([^=]*?\.split\(whereSeparator:(\{\$0\.isWhitespace\}|\\\.isWhitespace)\)\.joined\(separator:""\)"#
        return flat.ranges(of: try! Regex(copy)).count
    }

    @Test("squeezed steht einmal: keine Testdatei schreibt die Form selbst", .needsTheSources)
    func theSqueezeIsWrittenOnce() throws {
        var copies: [String: Int] = [:]
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["MaerTests"]) where name != "FetchAnswerTests.swift" {
            let count = Self.squeezeCopies(in: text)
            if count > 0 { copies[name] = count }
        }
        #expect(copies.isEmpty, "copies of FetchAnswerTests.squeezed: \(copies.sorted { $0.key < $1.key })")
        #expect(Self.squeezeCopies(in: "let a = SyncContractFenceTests.stripped(t).split(whereSeparator: { $0.isWhitespace }).joined(separator: \" \")") == 1)
        #expect(Self.squeezeCopies(in: "let a = SyncContractFenceTests.stripped(try String(contentsOf: u,\n    encoding: .utf8))\n        .split(whereSeparator:   \\.isWhitespace)\n        .joined(separator: \" \")") == 1,
                "a copy over lines and spaced otherwise is still a copy")
        #expect(Self.squeezeCopies(in: "let a = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: \" \")") == 0,
                "without stripping the comments it is another form")
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
