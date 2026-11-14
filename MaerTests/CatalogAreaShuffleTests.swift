// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every catalogue area page carries "Play something at random" in its
/// menu, with the draw of its catalogue; no row grows a button of its own.
struct CatalogAreaShuffleTests {
    @Test("the book shuffle asks the one base of the source, in the languages where the source has several")
    func theBookDrawAsksTheSourcesBase() throws {
        let librivox = try #require(CatalogShuffle.bookQuery(for: .librivox, languageCodes: ["de"]))
        #expect(librivox.hasPrefix(try #require(ArchiveOrgClient.archiveBaseQuery(for: .librivox)) + " AND ("))
        #expect(librivox.contains("language:"))
        #expect(CatalogShuffle.bookQuery(for: .archiveBooks, languageCodes: [])
                == ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks))
        // Old Time Radio is drawn whole, like its rows.
        #expect(CatalogShuffle.bookQuery(for: .oldTimeRadio, languageCodes: ["de"])
                == ArchiveOrgClient.archiveBaseQuery(for: .oldTimeRadio))
        #expect(CatalogShuffle.bookQuery(for: .gutenberg, languageCodes: ["de"]) == nil)
        #expect(CatalogShuffle.bookQuery(for: .oerr, languageCodes: ["de"]) == nil)
    }

    @Test("without a Jamendo key the shuffle names the cause, in the menu and at the row button", .needsTheSources)
    func aJamendoDrawWithoutKeyNamesTheCause() throws {
        let sentence = try #require(CatalogShuffle.jamendoMissing(clientId: nil))
        #expect(sentence.contains("Jamendo"))
        #expect(sentence != String(localized: "Shuffle found nothing to play this time. Please try again."))
        #expect(CatalogShuffle.jamendoMissing(clientId: "key") == nil)
        let shuffle = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/CatalogShuffle.swift"), encoding: .utf8))
        let jamendo = try #require(shuffle.components(separatedBy: "static func playJamendo(").last?
            .components(separatedBy: "JamendoClient.popularTracks").first)
        #expect(jamendo.contains("if let missing = jamendoMissing(clientId: JamendoClient.clientId())"),
                "the draw asks Jamendo without a key and says it found nothing")
        // The menu and the row button run the one draw.
        let layout = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/TabContentLayout.swift"), encoding: .utf8))
        #expect(layout.contains("Task { await CatalogShuffle.playJamendo(tags: tags, coordinator: coordinator) }"))
    }

    /// What the ends of a book draw were asked.
    @MainActor private final class Ends {
        var opened: [String] = []
        var failures: [String] = []
    }

    /// A wait that does not end when its task is cancelled, like an answer
    /// already on its way.
    private static func deafWait(_ ms: Int) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { done.resume() }
        }
    }

    @Test("a book shuffle whose page was left starts nothing and says nothing, even if the answer still came")
    @MainActor func aLeftDrawStartsNothing() async {
        let ends = Ends()
        let book = LibraryItem(id: "gut:1342", media: nil, addedAt: nil)
        let draw = Task { @MainActor in
            await CatalogShuffle.playBook(
                source: .gutenberg,
                draw: { await Self.deafWait(300); return [book] },
                open: { ends.opened.append($0.id) },
                fail: { ends.failures.append($0) })
        }
        try? await Task.sleep(for: .milliseconds(50))
        draw.cancel()
        await draw.value
        #expect(ends.opened.isEmpty && ends.failures.isEmpty, "\(ends.opened) \(ends.failures)")

        // Cancelled inside the request: the same silence.
        let thrown = Task { @MainActor in
            await CatalogShuffle.playBook(
                source: .gutenberg,
                draw: { try await Task.sleep(for: .seconds(5)); return [book] },
                open: { ends.opened.append($0.id) },
                fail: { ends.failures.append($0) })
        }
        try? await Task.sleep(for: .milliseconds(50))
        thrown.cancel()
        await thrown.value
        #expect(ends.opened.isEmpty && ends.failures.isEmpty, "\(ends.opened) \(ends.failures)")

        // A draw that keeps its page opens the title it drew.
        await CatalogShuffle.playBook(source: .gutenberg, draw: { await Self.deafWait(20); return [book] },
                                      open: { ends.opened.append($0.id) }, fail: { ends.failures.append($0) })
        #expect(ends.opened == ["gut:1342"] && ends.failures.isEmpty)
        await CatalogShuffle.playBook(source: .gutenberg, draw: { [] },
                                      open: { ends.opened.append($0.id) }, fail: { ends.failures.append($0) })
        #expect(ends.failures.count == 1, "an empty draw says nothing")
    }

    @Test("every area page carries the shuffle of its catalog in the menu, no row a new button", .needsTheSources)
    func everyAreaPageCarriesItsDraw() throws {
        func text(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .replacing(#/\s+/#, with: " ")
        }
        let music = try text("Sources/Views/Music/ArchiveMusicPages.swift")
        #expect(music.contains(".catalogShuffleActions { await CatalogShuffle.play(area: area, coordinator: playerCoordinator) }"))
        #expect(music.contains(".catalogShuffleActions { await CatalogShuffle.play(area: ArchiveMusicCatalog.shellacAll, coordinator: playerCoordinator) }"))
        let jamendo = try text("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(jamendo.contains(".catalogShuffleActions { await CatalogShuffle.playJamendo(coordinator: playerCoordinator) }"))
        let source = try text("Sources/Views/CatalogSourcePage.swift")
        #expect(source.contains(".catalogShuffleActions(shown: !source.isFeedBased) { await CatalogShuffle.playBook(source: source, coordinator: playerCoordinator) }"))
        // The draw is the page's task, shown while it waits, gone when the page goes.
        let layout = try text("Sources/Views/TabContentLayout.swift")
        let actions = try #require(layout.components(separatedBy: "private struct CatalogShuffleActions: ViewModifier {").last)
        #expect(actions.contains(".pageActions(\"catalog-actions\", shown: shown, busy: request != nil) { CatalogShuffleEntry(busy: request != nil) { request = UUID() } }"))
        #expect(actions.contains(".task(id: request) { guard let running = request else { return } await draw() if request == running { request = nil } }"))
        #expect(actions.contains(".onDisappear { request = nil }"), "a page that comes back draws again on its own")
        #expect(!layout.contains("Task { await draw() }"), "the draw runs past its page")
        let head = try text("Sources/Views/DetailHeader.swift")
        #expect(head.contains("if busy { ProgressView() } else { Image(systemName: \"ellipsis.circle\") }"),
                "the menu does not show the waiting draw")
        // The entry is built in one place.
        var labels: [String: Int] = [:]
        var rowButtons = 0
        for (name, raw) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            let stripped = SyncContractFenceTests.stripped(raw)
            let count = stripped.components(separatedBy: "Label(\"Play something at random\"").count - 1
            if count > 0 { labels[name] = count }
            rowButtons += stripped.components(separatedBy: ".catalogShuffle(area:").count - 1
            rowButtons += stripped.components(separatedBy: ".jamendoShuffle(").count - 1
        }
        #expect(labels == ["TabContentLayout.swift": 1], "\(labels)")
        // The row buttons that stood before: the shellac rows and the
        // netlabels and Jamendo rows of the music tab.
        #expect(rowButtons == 5)
    }
}
#endif
