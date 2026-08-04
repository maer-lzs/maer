// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 8d49a8e: the genre axes of the two catalog pages — radio plays (podcast
/// side) and free audiobooks (audiobook side). Pure data + pure mapping, so
/// both pages ask ONE truth and extending means adding an entry.
nonisolated enum CatalogGenreAxis {

    // MARK: - Radio plays: chip → Apple chart genre ids

    nonisolated struct Chip: Identifiable, Equatable {
        let key: String
        let title: String
        let systemImage: String
        /// One chip may bundle several charts.
        let genreIds: [Int]
        var id: String { key }
    }

    /// The chips, derived from what the DE charts ACTUALLY contain (measured
    /// 04.08.), not from what the genre names promise:
    ///
    /// - **Krimi → Drama (1484)**: that chart is headed by ARD Radio Tatort,
    ///   Kriminalhörspiel and "Schlechte Gesellschaft". Apple has no crime
    ///   sub-genre for fiction, and *True Crime* (1488) is documentary, not
    ///   radio play — including it would fill the chip with the wrong thing.
    /// - **Literatur → Fiction (1483) + Books (1482)**: readings and literary
    ///   adaptations sit in Books, the plays in Fiction.
    /// - **Kinder → Kids & Family (1305)**: Kakadu, Mikado and MausHörspiel
    ///   live there, not under Fiction.
    static let hoerspielChips: [Chip] = [
        Chip(key: "krimi", title: String(localized: "Crime"),
             systemImage: "magnifyingglass", genreIds: [1484]),
        Chip(key: "scifi", title: String(localized: "Science Fiction"),
             systemImage: "sparkles", genreIds: [1485]),
        Chip(key: "literatur", title: String(localized: "Literature"),
             systemImage: "book", genreIds: [1483, 1482]),
        Chip(key: "kinder", title: String(localized: "For Children"),
             systemImage: "figure.2.and.child.holdinghands", genreIds: [1305]),
        Chip(key: "komoedie", title: String(localized: "Comedy"),
             systemImage: "face.smiling", genreIds: [1486]),
    ]

    // MARK: - Free audiobooks: LibriVox genre → a user-facing axis

    /// LibriVox mixes GENRE and EPOCH in one field ("Literary Fiction",
    /// "Epistolary Fiction", "Published 1800-1900"). Showing it raw would put
    /// a year between the genres, so the epochs are dropped and the rest is
    /// folded onto a handful of shelves people actually browse by.
    /// Conservative: an unknown genre maps to nothing rather than to a guess.
    static let librivoxAxis: [String: String] = [
        // Fiction family
        "literary fiction": "fiction",
        "general fiction": "fiction",
        "epistolary fiction": "fiction",
        "historical fiction": "history",
        "romance": "romance",
        "love stories": "romance",
        "action & adventure fiction": "adventure",
        "adventure": "adventure",
        "nautical & marine fiction": "adventure",
        "detective fiction": "crime",
        "crime & mystery fiction": "crime",
        "mystery": "crime",
        "horror & supernatural fiction": "horror",
        "gothic fiction": "horror",
        "science fiction": "scifi",
        "fantastic fiction": "scifi",
        "humorous fiction": "comedy",
        "satire": "comedy",
        // Non-fiction / forms
        "poetry": "poetry",
        "single author collections": "poetry",
        "short stories": "shortstories",
        "children's fiction": "children",
        "children's literature": "children",
        "myths, legends & fairy tales": "fairytales",
        "fairy tales": "fairytales",
        "biography & autobiography": "biography",
        "memoirs": "biography",
        "history": "history",
        "philosophy": "philosophy",
        "plays": "drama",
        "drama": "drama",
    ]

    /// Shelf key → display title, in browse order.
    static let librivoxShelves: [(key: String, title: String)] = [
        ("fiction", String(localized: "Novels")),
        ("crime", String(localized: "Crime")),
        ("adventure", String(localized: "Adventure")),
        ("scifi", String(localized: "Science Fiction")),
        ("horror", String(localized: "Horror")),
        ("romance", String(localized: "Romance")),
        ("fairytales", String(localized: "Fairy Tales")),
        ("children", String(localized: "For Children")),
        ("shortstories", String(localized: "Short Stories")),
        ("poetry", String(localized: "Poetry")),
        ("drama", String(localized: "Plays")),
        ("history", String(localized: "History")),
        ("biography", String(localized: "Biographies")),
        ("comedy", String(localized: "Comedy")),
        ("philosophy", String(localized: "Philosophy")),
    ]

    /// A book's LibriVox genres → the shelves it belongs on (deduped, in
    /// browse order). Epochs and unknown entries drop out silently.
    static func shelves(forLibriVoxGenres genres: [String]) -> [String] {
        var hit = Set<String>()
        for genre in genres {
            let key = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let shelf = librivoxAxis[key] { hit.insert(shelf) }
        }
        return librivoxShelves.map(\.key).filter(hit.contains)
    }

    /// Is this LibriVox genre an EPOCH rather than a genre? (Only used to
    /// explain the drop in the log — the mapping ignores it either way.)
    static func isEpoch(_ genre: String) -> Bool {
        genre.range(of: #"\b1[0-9]{3}\b"#, options: .regularExpression) != nil
            || genre.lowercased().hasPrefix("published")
    }
}
