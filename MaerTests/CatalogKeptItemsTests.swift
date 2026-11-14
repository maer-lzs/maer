// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A catalog title resolved for playback names itself from the first
/// display on, also after a restart: the provider keeps its metadata on the
/// device, and every surface asks the provider by id.
struct CatalogKeptItemsTests {
    private func item(_ id: String, title: String?) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: "Frances Hodgson Burnett", narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 25046,
            chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: 25046,
                                   contentUrl: "https://archive.org/a.mp3", metadata: nil)]),
            addedAt: nil)
    }

    @Test("a title with a name is kept at the front, without tracks, once per identifier")
    func aNamedTitleIsKeptFirstWithoutTracks() {
        let garden = item("lva:secret_garden_version2_librivox", title: "The Secret Garden")
        let kept = CatalogKeptItems.adding(garden, to: [])
        #expect(kept.map(\.id) == [garden.id])
        #expect(kept.first?.media?.metadata?.title == "The Secret Garden")
        #expect(kept.first?.media?.metadata?.authorName == "Frances Hodgson Burnett")
        #expect(kept.first?.media?.duration == 25046)
        #expect(kept.first?.media?.tracks == nil)
        let other = item("lva:anneofgreengables_sp_librivox", title: "Anne of Green Gables")
        let again = CatalogKeptItems.adding(garden, to: CatalogKeptItems.adding(other, to: kept))
        #expect(again.map(\.id) == [garden.id, other.id])
    }

    @Test("a title without a name adds nothing, the limit keeps the newest")
    func anUnnamedTitleAddsNothingAndTheCapKeepsTheNewest() {
        let kept = CatalogKeptItems.adding(item("lva:a", title: "A"), to: [])
        #expect(CatalogKeptItems.adding(item("lva:b", title: nil), to: kept) == kept)
        #expect(CatalogKeptItems.adding(item("lva:b", title: ""), to: kept) == kept)
        let full = (0..<5).reduce([LibraryItem]()) { CatalogKeptItems.adding(item("lva:\($1)", title: "T\($1)"), to: $0, cap: 3) }
        #expect(full.map(\.id) == ["lva:4", "lva:3", "lva:2"])
    }

    @Test("an entry from the row keeps its title and takes the duration of the resolved title where it has none")
    func aRowEntryKeepsItsTitleAndTakesTheDuration() {
        let row = LibraryItem(id: "lva:bbc", media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "BBC Sci-Fi Radio Plays", authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: ["Radio"], publishedYear: nil, description: nil),
            duration: nil, chapters: nil, tracks: nil), addedAt: 7)
        let resolved = item("lva:bbc", title: "BBC Sci-Fi Radio Plays - Part Four")
        let merged = CatalogKeptItems.merged(known: row, resolved: resolved)
        #expect(merged.media?.metadata?.title == "BBC Sci-Fi Radio Plays")
        #expect(merged.media?.metadata?.genres == ["Radio"])
        #expect(merged.media?.duration == 25046)
        #expect(merged.media?.tracks?.count == 1)
        #expect(merged.addedAt == 7)
        // Without a titled entry the resolved item stands.
        #expect(CatalogKeptItems.merged(known: nil, resolved: resolved) == resolved)
        #expect(CatalogKeptItems.merged(known: item("lva:bbc", title: nil), resolved: resolved) == resolved)
    }

    /// A kept document that is there and does not read (before the first
    /// unlock) is not empty: nothing is saved over it, and once it reads the
    /// titles of the run go in front of it.
    @Test("a kept document that does not read is not overwritten; if it reads again, the titles of the run come before it")
    @MainActor
    func anUnreadKeptDocumentIsNotReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-unread-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ablage = Ablage(directory: directory)
        let document = ablage.url(for: FreeCatalogProvider.keptDocument)
        let old = CatalogKeptItems.adding(item("lva:old", title: "Old"), to: [])
        try JSONEncoder().encode(old).write(to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: document.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path) }
        #expect(ablage.liesUnreadInPlace(FreeCatalogProvider.keptDocument), "the precondition: the document does not read")

        let provider = FreeCatalogProvider(ablage: ablage)
        provider.keep(item("lva:first", title: "First"))
        await provider.awaitPendingSave()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path)
        let untouched = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: document))
        #expect(untouched.map(\.id) == ["lva:old"], "the run saved over a document it did not read")

        provider.keep(item("lva:second", title: "Second"))
        await provider.awaitPendingSave()
        let saved = try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: document))
        #expect(saved.map(\.id) == ["lva:second", "lva:first", "lva:old"], "the document read late lost a title")
    }

    @Test("the provider loads the kept titles at start and keeps what it resolves; Continue Listening names the unnamed ones", .needsTheSources)
    func theProviderKeepsAndContinueNames() throws {
        let read = { (path: String) in
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let provider = try read("Sources/Providers/FreeCatalogProvider.swift")
        #expect(provider.contains("kept = Self.readKept(ablage)"))
        #expect(provider.contains("(ablage.loadNow([LibraryItem].self, name: keptDocument).value ?? []).map(FreeCatalog.gutenbergReadable)"))
        #expect(provider.contains("static let shared = FreeCatalogProvider(ablage: .documents)"))
        #expect(provider.contains("resolved: LibraryItem(id: detail.id, media: detail.media, addedAt: nil))\n        keep(item)\n        itemsById[detail.id] = item"))
        // Each resolve goes through `rememberResolved`: LibriVox, the archive
        // item, its song, Jamendo and Gutenberg, beside the declaration.
        #expect(provider.components(separatedBy: "rememberResolved(").count - 1 == 6)
        let library = try read("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("let extras = Self.continueExtras()\n        nameUnnamedCatalogTitles(extras)"))
    }
}
#endif
