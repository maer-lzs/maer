// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What the browse deck derives from the own stock. The build lived inside
/// the search view and was therefore untestable: the groups, the letter
/// blocks of the A to Z rail and the sorting could only be checked by
/// looking at the screen.
struct SearchDeckTests {
    private func entry(_ id: String, _ title: String,
                       author: String? = nil, series: String? = nil,
                       genres: [String]? = nil) -> LibraryEntry {
        LibraryEntry(item: LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: title, authorName: author, narratorName: nil,
                    seriesName: series, genres: genres, publishedYear: nil, description: nil),
                duration: 100, chapters: nil, tracks: nil),
            addedAt: nil), progress: nil)
    }

    private func album(_ id: String, _ title: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: title, authorName: nil, narratorName: nil, seriesName: nil,
                genres: nil, publishedYear: nil, description: nil),
            duration: 0, chapters: nil, tracks: nil), addedAt: nil)
    }

    private func show(_ feed: String, _ title: String) -> PodcastShow {
        PodcastShow(id: "rss:\(feed)", title: title, author: nil, artworkURL: nil,
                    description: nil, feedURL: feed, episodes: [])
    }

    @Test("Series fold upper and lower case and diacritics into ONE group")
    func seriesFoldIntoOneGroup() {
        let deck = SearchDeck.build(entries: [
            entry("b1", "Zeta", series: "Saga #2"),
            entry("b2", "Alpha", series: "saga #1"),
            entry("b3", "Beta", series: "Sága #3"),
            entry("b4", "Solo", series: nil),
        ], shows: [], albums: [])
        #expect(deck.seriesGroups.count == 1, "aus drei Schreibweisen wurde mehr als eine Reihe")
        #expect(deck.seriesGroups.first?.entries.count == 3)
        // A book without a series is in none.
        #expect(deck.seriesGroups.first?.entries.contains { $0.id == "b4" } == false)
    }

    @Test("The letter blocks follow the folded first letter")
    func letterSectionsFoldTheFirstLetter() {
        let deck = SearchDeck.build(entries: [
            entry("b1", "Ärger"),
            entry("b2", "Alpha"),
            entry("b3", "Beta"),
            entry("b4", "1984"),
        ], shows: [], albums: [])
        #expect(deck.letterSections.map(\.letter) == ["#", "A", "B"])
        // „Ärger" belongs under A, not under Ä and not under #.
        #expect(deck.letterSections.first { $0.letter == "A" }?.entries.count == 2)
        #expect(deck.letterSections.first { $0.letter == "#" }?.entries.map(\.id) == ["b4"])
    }

    @Test("Shows and albums are in alphabetical order, regardless of arrival")
    func showsAndAlbumsAreSorted() {
        let deck = SearchDeck.build(
            entries: [],
            shows: [show("f2", "Zweite"), show("f1", "Erste")],
            albums: [album("a2", "Zebra"), album("a1", "Anfang")])
        #expect(deck.shows.map(\.title) == ["Erste", "Zweite"])
        #expect(deck.albums.map(\.title) == ["Anfang", "Zebra"])
    }

    @Test("The stock per entry point comes from the deck, the artist count from outside")
    func countsComeFromTheDeck() {
        var deck = SearchDeck.build(entries: [
            entry("b1", "Alpha", author: "Adams", series: "Saga #1", genres: ["Krimi"]),
            entry("b2", "Beta", author: "Brown", genres: ["Krimi", "科幻"]),
        ], shows: [show("f1", "Erste")], albums: [album("a1", "Anfang")])
        #expect(deck.counts.authors == 2)
        #expect(deck.counts.series == 1)
        #expect(deck.counts.shows == 1)
        #expect(deck.counts.albums == 1)
        // The music source has not answered yet: no invented number.
        #expect(deck.counts.artists == nil)
        deck.artistCount = 9
        #expect(deck.counts.artists == 9)
    }

    @Test("An empty stock gives an empty deck, no placeholders")
    func anEmptyStockGivesAnEmptyDeck() {
        let deck = SearchDeck.build(entries: [], shows: [], albums: [])
        #expect(deck.letterSections.isEmpty)
        #expect(deck.authorGroups.isEmpty)
        #expect(deck.seriesGroups.isEmpty)
        #expect(deck.counts == SearchDeckCounts())
    }
}
#endif
