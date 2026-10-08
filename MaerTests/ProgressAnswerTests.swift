// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A failed progress fetch replaces no known progress, on every load path.
@MainActor
struct ProgressAnswerTests {
    private func item(_ id: String) -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "T", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: 1
        )
    }

    @Test("die Regel: ein gescheiterter Abruf ersetzt keinen bekannten Fortschritt")
    func theRule() {
        let known = ["b1": BookProgress(fraction: 0.4, isFinished: false, lastUpdate: 1)]
        let fetched = ["b1": BookProgress(fraction: 0.6, isFinished: false, lastUpdate: 2)]
        #expect(ProgressAnswer.of(nil, known: known) == known)
        #expect(ProgressAnswer.of(fetched, known: known) == fetched)
        #expect(ProgressAnswer.of([:], known: known).isEmpty, "an answered empty map is an answer")
    }

    @Test("die Seiten kommen, der Fortschritt scheitert: die Balken bleiben")
    func theBarsStayWhenTheProgressFails() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = MockProvider()
        provider.items = [item("b1"), item("b2")]
        provider.progress = ["b1": BookProgress(fraction: 0.4, isFinished: false, lastUpdate: 1)]
        let vm = LibraryViewModel(provider: provider,
                                  database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
        await vm.loadLibrary()
        #expect(vm.entries.first(where: { $0.id == "b1" })?.progress?.fraction == 0.4, "the precondition")

        provider.failProgress = true
        await vm.loadLibrary()
        #expect(vm.entries.map(\.id).sorted() == ["b1", "b2"], "the pages arrived")
        #expect(vm.entries.first(where: { $0.id == "b1" })?.progress?.fraction == 0.4,
                "a failed progress fetch wiped the bar")
    }

    @Test("kein Ladeweg setzt bei einem Fehlschlag leeren Fortschritt", .needsTheSources)
    func noLoadPathFallsBackToEmpty() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/LibraryViewModel.swift"), encoding: .utf8))
        let squeezed = code.filter { !$0.isWhitespace }
        #expect(!squeezed.contains("progressTask)??[:]"))
        // Every caller of the question, not one file: a failure answered with
        // an empty map wipes the progress wherever it lands (the start page's
        // music rows had exactly this form).
        let callers = ProjectFileIntegrityTests.sourceTexts().filter { $0.text.contains("fetchAllProgress()") }
        #expect(Set(["LibraryViewModel.swift", "HomeView.swift"]).isSubset(of: callers.map(\.name)),
                "the fence does not read the callers it is about: \(callers.map(\.name))")
        let empty = callers.filter { file in
            SyncContractFenceTests.stripped(file.text).filter { !$0.isWhitespace }.contains("fetchAllProgress())??[:]")
        }.map(\.name)
        #expect(empty.isEmpty, "a caller answers a failure with an empty map: \(empty)")
        #expect(code.components(separatedBy: "ProgressAnswer.of(").count - 1 == 3, "the three load paths ask the one rule")
        // The secondary sources keep what their entries carried.
        #expect(code.contains("ProgressAnswer.of(fetched, known: known)"))
        #expect(code.contains("for entry in localCache { if let progress = entry.progress { known[entry.id] = progress } }"))
    }
}
#endif
