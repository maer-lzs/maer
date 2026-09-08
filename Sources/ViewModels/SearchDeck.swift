// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A letter block of the alphabetical book raster, with the anchor the
/// A to Z rail jumps to.
nonisolated struct SearchDeckLetterSection {
    let letter: String
    let entries: [LibraryEntry]
}

/// Everything the browse deck derives from the own stock, built in ONE
/// pass off the main thread. Grouping and ICU sorts over every book,
/// show and album are expensive enough to be visible as a stall, so they
/// run once per content change and never per body evaluation.
nonisolated struct SearchDeck {
    var authorGroups: [(name: String, entries: [LibraryEntry])] = []
    var genreGroups: [(name: String, entries: [LibraryEntry])] = []
    var seriesGroups: [(name: String, entries: [LibraryEntry])] = []
    var letterSections: [SearchDeckLetterSection] = []
    var shows: [PodcastShow] = []
    var albums: [LibraryItem] = []
    /// What the music source answered about its artists, nil while it has
    /// not answered. It travels WITH the deck so the view holds one state
    /// for the deck instead of two.
    var artistCount: Int?

    /// The stock behind each entry point, for the tile rule.
    var counts: SearchDeckCounts {
        SearchDeckCounts(authors: authorGroups.count, series: seriesGroups.count,
                         genres: genreGroups.count, shows: shows.count,
                         albums: albums.count, artists: artistCount)
    }

    static func build(entries: [LibraryEntry], shows: [PodcastShow],
                      albums: [LibraryItem]) -> SearchDeck {
        var deck = SearchDeck()
        deck.authorGroups = LibraryViewModel.authorGroups(of: entries)
        deck.genreGroups = LibraryViewModel.genreGroups(of: entries)
        // Series grouped like the author groups. Key-folded dedupe, sorted.
        var indexByKey: [String: Int] = [:]
        var groups: [(name: String, entries: [LibraryEntry])] = []
        for entry in entries {
            guard let name = LibraryViewModel.baseSeriesName(entry.item.media?.metadata?.seriesName) else { continue }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let idx = indexByKey[key] {
                groups[idx].entries.append(entry)
            } else {
                indexByKey[key] = groups.count
                groups.append((name: name, entries: [entry]))
            }
        }
        deck.seriesGroups = groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Alphabetical, diacritic-folded; no letter start lands in "#".
        let sorted = entries.sorted {
            $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }
        var sections: [SearchDeckLetterSection] = []
        for entry in sorted {
            let first = entry.item.title.first.map {
                String($0).folding(options: .diacriticInsensitive, locale: nil).uppercased()
            } ?? "#"
            let letter = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
            if let last = sections.indices.last, sections[last].letter == letter {
                sections[last] = SearchDeckLetterSection(letter: letter, entries: sections[last].entries + [entry])
            } else {
                sections.append(SearchDeckLetterSection(letter: letter, entries: [entry]))
            }
        }
        deck.letterSections = sections
        deck.shows = shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        deck.albums = albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return deck
    }
}

/// The in-page drill levels of the deck. The stack itself is view state,
/// because it is navigation; what a level HOLDS and what it is called is
/// data and lives here.
nonisolated enum SearchDeckDrill {
    case groups(title: String, groups: [(name: String, entries: [LibraryEntry])])
    case entries(title: String, entries: [LibraryEntry])
    case artists(title: String, artists: [MusicArtist])
    /// Catalog shows of ONE podcast genre, with an honesty line when the
    /// directory answered short.
    case catalogShows(title: String, results: [SearchResult], footer: String? = nil)

    var title: String {
        switch self {
        case .groups(let title, _), .entries(let title, _), .artists(let title, _),
             .catalogShows(let title, _, _):
            return title
        }
    }
}
