// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Browsing the catalogues shows only titles with a cover: a title whose
/// source names no cover, or whose cover answered "none here", is left out
/// when a page or shelf is built. The search keeps them, a page on screen
/// keeps its tiles, and "none here" ages: after 30 days the cover is asked
/// again, since archive.org often makes its pictures later.
@MainActor
struct CatalogBrowseCoverTests {
    typealias Rule = CatalogCoverRule

    private static func suite() -> (UserDefaults, String) {
        let name = "browse-cover-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("the rule shows a title only with a cover address that did not answer none")
    func theRule() throws {
        let url = try #require(URL(string: "https://archive.org/services/img/x"))
        #expect(!Rule.shows(coverURL: nil, isAbsent: { _ in false }), "no address, no title")
        #expect(!Rule.shows(coverURL: url, isAbsent: { _ in true }), "an absent cover, no title")
        #expect(Rule.shows(coverURL: url, isAbsent: { _ in false }))
    }

    @Test("the catalogue cover addresses: archive.org's image service, Gutenberg's covers, Jamendo's pictures; nothing else")
    func catalogueAddresses() throws {
        for raw in ["https://archive.org/services/img/OTRR_Item", "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg",
                    "https://usercontent.jamendo.com/?type=album&id=1&width=300"] {
            #expect(Rule.isCatalogCover(try #require(URL(string: raw))), "\(raw)")
        }
        for raw in ["https://archive.org/download/x/cover.jpg", "https://example.org/artwork.jpg",
                    "https://www.gutenberg.org/ebooks/1342"] {
            #expect(!Rule.isCatalogCover(try #require(URL(string: raw))), "\(raw)")
        }
    }

    @Test("none here holds 30 days, also across a restart, then the cover is asked again")
    func noneHereAges() throws {
        let (defaults, name) = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: name); AbsentCovers.dropSessionCopy() }
        AbsentCovers.dropSessionCopy()
        let url = try #require(URL(string: "https://archive.org/services/img/AGES"))
        let day: Double = 24 * 3600
        let t0: Double = 1_800_000_000
        AbsentCovers.insert(url, now: t0, defaults: defaults)
        #expect(AbsentCovers.contains(url, now: t0 + 29 * day, defaults: defaults))
        AbsentCovers.flush(defaults: defaults)
        AbsentCovers.dropSessionCopy()
        #expect(AbsentCovers.contains(url, now: t0 + 29 * day, defaults: defaults), "the date survives the restart")
        #expect(!AbsentCovers.contains(url, now: t0 + 31 * day, defaults: defaults), "after 31 days it shows again")
        #expect(Rule.stillAbsent(since: t0, now: t0 + 29 * day))
        #expect(!Rule.stillAbsent(since: t0, now: t0 + 31 * day))
    }

    @Test("a missing catalogue cover is noted, a missing cover elsewhere is not")
    func onlyCatalogueAbsencesAreNoted() throws {
        let (defaults, name) = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: name); AbsentCovers.dropSessionCopy() }
        AbsentCovers.dropSessionCopy()
        let catalogue = try #require(URL(string: "https://www.gutenberg.org/cache/epub/9/pg9.cover.medium.jpg"))
        let podcast = try #require(URL(string: "https://example.org/show.jpg"))
        AbsentCovers.noteAbsent(catalogue, defaults: defaults)
        AbsentCovers.noteAbsent(podcast, defaults: defaults)
        #expect(AbsentCovers.contains(catalogue, defaults: defaults))
        #expect(!AbsentCovers.contains(podcast, defaults: defaults))
    }

    @Test("a page leaves out a LibriVox reading without an archive copy, a Jamendo song without a picture and a title whose cover is absent; the rest stays in order")
    func browsingLeavesTitlesWithoutCover() throws {
        AbsentCovers.dropSessionCopy()
        defer { AbsentCovers.dropSessionCopy() }
        let provider = FreeCatalogProvider.shared
        // A reading without an archive copy and a song without a picture.
        let reading = provider.remember(book: LibriVoxBook(
            id: "cover-\(UUID().uuidString)", title: "T", language: "English", totaltimesecs: 60, url_iarchive: nil,
            url_librivox: nil, url_rss: nil, authors: nil, sections: [], genres: nil))
        let song = try #require(provider.remember(track: JamendoTrack(
            id: "cover-\(UUID().uuidString)", name: "T", artist_name: "A", image: nil,
            audio: "https://example.org/a.mp3", shareurl: nil, duration: 60)))
        let gone = try #require(provider.remember(popular: CatalogLoaderWitness.doc()))
        let kept = try #require(provider.remember(popular: CatalogLoaderWitness.doc()))
        let alsoKept = try #require(provider.remember(popular: CatalogLoaderWitness.doc()))
        AbsentCovers.insert(try #require(provider.coverURL(forItemId: gone.id)))
        let shown = Rule.browsable([reading, kept, song, gone, alsoKept], register: provider).map(\.id)
        #expect(shown == [kept.id, alsoKept.id])
    }

    private static func text(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Fence: every entry a browse builder makes passes the rule, the search and the tile never ask it", .needsTheSources)
    func theBuildersFilter() throws {
        let write = #/\.remember\(\s*(?:popular|gutenberg|book|track)\s*:/#
        for path in ["Sources/ViewModels/CatalogShelfEntries.swift", "Sources/ViewModels/FreeCatalogLoader.swift",
                     "Sources/ViewModels/ArchiveMusicLoader.swift", "Sources/ViewModels/JamendoLoader.swift",
                     "Sources/ViewModels/CatalogSourceLoader.swift"] {
            let lines = try Self.text(path).split(separator: "\n")
            let writes = lines.filter { !$0.matches(of: write).isEmpty }
            #expect(!writes.isEmpty, "\(path): the fence found no entry")
            for line in writes {
                #expect(line.contains("CatalogCoverRule.browsable("), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(!(try Self.text("Sources/ViewModels/GlobalSearchModel.swift")).contains("browsable("), "the search keeps every title")
        let tile = try Self.text("Sources/Views/FeedArtwork.swift")
        #expect(!tile.contains("browsable(") && !tile.contains("AbsentCovers"), "a tile on screen stays where it is")
    }

    @Test("Fence: the door notes an absence it learned from the network, never an unanswered question", .needsTheSources)
    func theDoorNotesAbsences() throws {
        let text = try Self.text("Sources/Networking/Artwork.swift")
        let notes = text.split(separator: "\n").filter { $0.contains("AbsentCovers.noteAbsent(url)") }
        #expect(notes.count == 2, "both network answers of the verdict note an absence")
        #expect(notes.allSatisfy { $0.contains("case .absent:") })
    }
}
#endif
