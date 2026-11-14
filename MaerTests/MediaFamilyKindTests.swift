// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A server id's family comes from its namespace AND its kind. The namespace
/// alone called every Jellyfin id music, so a Jellyfin audiobook took the
/// music title buttons, the music tools and the music placeholder.
struct MediaFamilyKindTests {
    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("family: every kind under jf: and sub: has a target, an unknown kind is visibly unknown")
    func everyKindHasATarget() {
        let table: [(String, MediaFamily)] = [
            ("jf:album:1", .music), ("jf:song:1", .music), ("jf:playlist:1", .music), ("jf:artist:1", .music),
            ("jf:book:b1", .book), ("jf:book:folded", .book), ("jf:books:v-books", .book),
            ("sub:album:1", .music), ("sub:song:1", .music), ("sub:playlist:1", .music), ("sub:artist:1", .music),
            // Visible, never quietly music.
            ("jf:1", .unknown), ("jf:video:1", .unknown), ("sub:unknown-9", .unknown), ("sub:", .unknown),
        ]
        for (id, family) in table {
            #expect(MediaFamily.of(id) == family, "\(id) must be \(family)")
        }
    }

    @Test("family: every kind a provider issues is in the table", .needsTheSources)
    func everyKindTheProvidersHandOutIsListed() throws {
        for (file, namespace) in [("Sources/Providers/JellyfinProvider.swift", "jf:"),
                                  ("Sources/Providers/SubsonicProvider.swift", "sub:")] {
            let text = try Self.source(file)
            // The kinds a provider builds ids with: `kind: "x"` and literal
            // `"<ns><kind>:` prefixes.
            let pattern = #"kind: "([a-z]+)"|"\#(namespace)([a-z]+):"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            var kinds: Set<String> = []
            for match in regex.matches(in: text, range: range) {
                for group in 1...2 {
                    if let r = Range(match.range(at: group), in: text) { kinds.insert(String(text[r])) }
                }
            }
            #expect(!kinds.isEmpty, "the precondition: \(file) was read")
            let listed = Set(MediaFamily.serverKinds[namespace]?.keys.map { $0 } ?? [])
            #expect(kinds.subtracting(listed).isEmpty,
                    "\(namespace) kinds without a family: \(kinds.subtracting(listed).sorted())")
        }
    }

    @Test("Jellyfin book: book for every question that separates the book from music")
    func aJellyfinBookIsABookEverywhere() {
        let book = "jf:book:b1"
        #expect(MediaFamily.booksTabMember(book, markedForm: nil), "Continue of the books tab")
        #expect(!MediaFamily.isMusicByForm(book), "spoken-word tools and skips")
        #expect(PlaybackSkip.content(forItemId: book) == .spokenWord)
        #expect(MediaFamily.placeholderSymbol(for: book) == MediaType.audiobooks.systemImage)
        #expect(MediaFamily.musicCount(in: [book, "jf:song:1"]) == 1)
        #expect(PlayerSourceTargets.isBook(book) && !PlayerSourceTargets.isMusic(book))
        #expect(DownloadKind.audiobooks.ids(in: [book], recorded: [:], sole: { _ in nil }) == [book],
                "an audiobook download even without a recorded kind")
        // Its stand lives on Jellyfin: the Audiobookshelf library is not
        // refreshed for it; a bare id still refreshes it.
        #expect(ClaimRefreshThrottle.library(of: book) == nil)
        #expect(ClaimRefreshThrottle.library(of: "8f2a-uuid") == .books)
        #expect(ClaimRefreshThrottle.library(of: "local:file") == nil)
        // The music of the same server stays music.
        #expect(MediaFamily.isMusicByForm("jf:album:1") && MusicSourceRule.isServerMusic("jf:album:1"))
        #expect(!MusicSourceRule.isServerMusic("jf:book:7"), "a Jellyfin audiobook is no music")
    }

    @Test("the identifier behind a Jellyfin address is read by the pure layer, the provider asks it there")
    func theJellyfinIdIsPure() {
        #expect(ItemNamespace.jellyfinId("jf:book:7", kind: "book") == "7")
        #expect(ItemNamespace.jellyfinId("jf:album:a:b", kind: "album") == "a:b")
        #expect(ItemNamespace.jellyfinId("jf:album:1", kind: "book") == nil)
        #expect(ItemNamespace.jellyfinId("sub:book:7", kind: "book") == nil)
        #expect(JellyfinProvider.id("jf:song:9", kind: "song") == ItemNamespace.jellyfinId("jf:song:9", kind: "song"))
    }

    @Test("a catalog song is music in the player: the artist is under the title", .needsTheSources)
    func aCatalogSongIsMusicInThePlayer() throws {
        let song = CatalogSongID.make(album: FreeCatalog.archivePrefix + "MIXG032", index: 0)
        #expect(MediaFamily.isMusicByForm(song))
        // A release unmarked stays a reading: its one position is kept.
        #expect(!MediaFamily.isMusicByForm(FreeCatalog.archivePrefix + "MIXG032"))
        // The player asks the one form question, not the family alone,
        // with the form of its one place (`PlayingFormTests`).
        let player = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+NowPlaying.swift"),
            encoding: .utf8))
        #expect(player.contains("var isMusicItem: Bool { item.map { MediaFamily.isMusicByForm($0.id, markedForm: playingForm) } == true }"))
    }
}
#endif
