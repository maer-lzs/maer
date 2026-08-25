// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
        // P5/P7: the measured new shelves (IA religion, OTR western + variety).
        ("religion", String(localized: "Religion")),
        ("western", String(localized: "Western")),
        ("music", String(localized: "Music & Variety")),
    ]

    /// 9ef73a4: Gutenberg LCSH subjects → the SAME shelves. Regel 2: one
    /// axis, extended — no GutenbergGenreAxis next to it. the measurement of
    /// the 1,124 audio titles drove the entries (Domestic fiction 15 · Love
    /// stories 15 · Adventure stories 13 · Bildungsromans 9 · Satire 6 ·
    /// Historical fiction 5); four of them already sat in librivoxAxis
    /// verbatim. LCSH facets ("England -- Fiction") are split and each half
    /// tried — the qualifier carries the genre.
    static let lcshAxis: [String: String] = [
        "fiction": "fiction",
        "domestic fiction": "fiction",
        "bildungsromans": "fiction",
        "adventure stories": "adventure",
        "sea stories": "adventure",
        "war stories": "adventure",
        "detective and mystery stories": "crime",
        "horror tales": "horror",
        "ghost stories": "horror",
        "humorous stories": "comedy",
        "children's stories": "children",
        "juvenile fiction": "children",
        "fairy tales": "fairytales",
        "folklore": "fairytales",
        "autobiography": "biography",
        "biography": "biography",
        // P5 (1dfdca7, full-stock measurement over 4,257 IA titles — 26%
        // shelve): the IA subjects speak plainly; philosophy/poetry already
        // map via librivoxAxis, religion is a NEW shelf (80 titles).
        "religion": "religion",
        "christianity": "religion",
        "bible": "religion",
        "theology": "religion",
        // P7 (38511f1, full-stock measurement over 2,314 OTR bundles — 40%
        // shelve): plain OTR subject terms; suspense counts into the horror
        // shelf (the Horror/Suspense 114 is ONE shelf), western and
        // music/variety are NEW shelves (82 / 159 bundles).
        "crime": "crime",
        // R47 (the reviewer's Messung ueber 300 OTR-Items): diese Begriffe sind
        // haeufiger als manches, das die Achse schon kannte — sie fehlten
        // schlicht. Exakte Terme wie alle anderen, kein Teilstring.
        "detective": "crime",
        "mystery": "crime",
        "crime drama": "crime",
        "drama": "drama",
        "comedy": "comedy",
        "horror": "horror",
        "suspense": "horror",
        "thriller": "horror",
        "western": "western",
        "westerns": "western",
        "music": "music",
        "musical": "music",
        "variety": "music",
        "sci-fi": "scifi",
        "children": "children",
    ]

    /// P8 (cde97a9, measured over 200 popular tracks — 93% carry tags, the
    /// best axis of all sources): the MUSIC genre family. Related tags fold
    /// onto their parent shelf as AXIS entries (electropop→pop), no special
    /// code; netlabels inherits this axis later. Server-side use: the shelf
    /// query sends ALL its tags (fuzzytags OR-join) via `musicTags(forShelf:)`.
    /// R-Musik (the owner's ENTSCHEID: „Falte die ganzen sehr kleinen Töpfe …
    /// bleiben wir bei circa 30"): the folded axis. Two spelling families ride
    /// in ONE table — Jamendo writes its tags without separators
    /// (`electropop`, `singersongwriter`), archive.org subjects use spaces and
    /// hyphens (`trip-hop`, `drum and bass`). Lookup normalises both sides, so
    /// each term is listed ONCE, in the form the SOURCE queries with.
    ///
    /// Measured before building (1.000 netlabel titles, 200 Jamendo tracks):
    /// the old 14-term axis covered 36,0 % of netlabels and 81,0 % of Jamendo.
    /// The ceiling is what carries terms at all — 93,5 % / 98,0 %.
    static let musicAxis: [String: String] = [
        // electronic — the big fold: every club and machine sub-genre
        "electronic": "electronic", "electro": "electronic",
        "electronica": "electronic", "idm": "electronic", "techno": "electronic",
        "house": "electronic", "deep house": "electronic", "tech house": "electronic",
        "trance": "electronic", "psytrance": "electronic", "dance": "electronic",
        "edm": "electronic", "club": "electronic", "disco": "electronic",
        "drum and bass": "electronic", "dnb": "electronic", "jungle": "electronic",
        "breaks": "electronic", "breakbeat": "electronic", "broken beat": "electronic",
        "glitch": "electronic", "downtempo": "electronic", "trip-hop": "electronic",
        "dub": "electronic", "dubstep": "electronic", "minimal": "electronic",
        "acid": "electronic", "chiptune": "electronic", "8bit": "electronic",
        "synth": "electronic", "synthwave": "electronic", "vaporwave": "electronic",
        "ebm": "electronic", "electroacoustic": "electronic", "beats": "electronic",
        // ambient
        "ambient": "ambient", "chillout": "ambient", "chill": "ambient",
        "drone": "ambient", "soundscape": "ambient", "new age": "ambient",
        "dark ambient": "ambient", "atmospheric": "ambient", "ethereal": "ambient",
        "meditation": "ambient", "space music": "ambient",
        // experimental
        "experimental": "experimental", "noise": "experimental",
        "avant-garde": "experimental", "sound art": "experimental",
        "improvisation": "experimental", "free improvisation": "experimental",
        "musique concrete": "experimental", "field recording": "experimental",
        "abstract": "experimental", "plunderphonics": "experimental",
        "collage": "experimental", "turntablism": "experimental",
        "lowercase": "experimental",
        // rock
        "rock": "rock", "alternative": "rock", "punk": "rock", "metal": "rock",
        "psychedelic": "rock", "progressive": "rock", "prog-rock": "rock",
        "post-rock": "rock", "post-punk": "rock", "garage": "rock",
        "grunge": "rock", "shoegaze": "rock", "hard rock": "rock",
        "indie rock": "rock", "stoner": "rock", "surf": "rock", "emo": "rock",
        "math rock": "rock", "noise rock": "rock", "hardcore": "rock",
        "grindcore": "rock", "doom": "rock", "black metal": "rock",
        "death metal": "rock", "sludge": "rock", "screamo": "rock",
        // indie
        "indie": "indie", "lo-fi": "indie", "lofi": "indie", "bedroom": "indie",
        "diy": "indie", "underground": "indie",
        // pop
        "pop": "pop", "electropop": "pop", "poprock": "pop", "synthpop": "pop",
        "dream pop": "pop", "power pop": "pop", "indiepop": "pop",
        "alternativepop": "pop", "art pop": "pop", "chanson": "pop",
        // hiphop
        "hiphop": "hiphop", "hip-hop": "hiphop", "rap": "hiphop",
        "instrumental hip-hop": "hiphop", "abstract hip-hop": "hiphop",
        "boom bap": "hiphop", "trap": "hiphop",
        // jazz
        "jazz": "jazz", "nu jazz": "jazz", "bebop": "jazz", "swing": "jazz",
        "fusion": "jazz", "jazzy": "jazz", "free jazz": "jazz",
        "big band": "jazz", "lounge": "jazz",
        // folk
        "folk": "folk", "singersongwriter": "folk", "acoustic": "folk",
        "country": "folk", "alt-country": "folk", "americana": "folk",
        "bluegrass": "folk", "fingerstyle": "folk",
        // soul
        "soul": "soul", "funk": "soul", "rnb": "soul", "r&b": "soul",
        "gospel": "soul", "motown": "soul", "rocksteady": "soul",
        // blues
        "blues": "blues", "delta blues": "blues", "boogie": "blues",
        // classical
        "classical": "classical", "neoclassical": "classical",
        "contemporary classical": "classical", "modern classical": "classical",
        "piano": "classical", "orchestral": "classical", "baroque": "classical",
        "chamber music": "classical", "opera": "classical", "cello": "classical",
        "violin": "classical", "classical guitar": "classical",
        // world
        "world": "world", "reggae": "world", "ska": "world", "latin": "world",
        "afrobeat": "world", "tribal": "world", "ethnic": "world",
        "balkan": "world", "flamenco": "world", "celtic": "world",
        "oriental": "world", "bossa nova": "world", "cumbia": "world",
        "salsa": "world", "gypsy": "world", "roots": "world",
        // soundtrack
        "soundtrack": "soundtrack", "filmscore": "soundtrack",
        "film score": "soundtrack", "score": "soundtrack",
        "game music": "soundtrack", "videogame": "soundtrack",
        // spoken
        "spoken": "spoken", "spoken word": "spoken", "poetry": "spoken",
        "audiobook": "spoken",
        // gothic — measured as its own family in the netlabel stock
        "gothic": "gothic", "industrial": "gothic", "darkwave": "gothic",
        "coldwave": "gothic", "minimal wave": "gothic", "goth": "gothic",
    ]

    /// Shelf key → display title, in browse order.
    static let musicShelves: [(key: String, title: String)] = [
        ("electronic", String(localized: "Electronic")),
        ("ambient", String(localized: "Ambient")),
        ("experimental", String(localized: "Experimental")),
        ("rock", String(localized: "Rock")),
        ("indie", String(localized: "Indie")),
        ("pop", String(localized: "Pop")),
        ("hiphop", String(localized: "Hip-Hop")),
        ("jazz", String(localized: "Jazz")),
        ("folk", String(localized: "Folk")),
        ("soul", String(localized: "Soul & Funk")),
        ("blues", String(localized: "Blues")),
        ("classical", String(localized: "Classical")),
        ("world", String(localized: "World")),
        ("soundtrack", String(localized: "Soundtrack")),
        ("gothic", String(localized: "Gothic & Industrial")),
        ("spoken", String(localized: "Spoken Word")),
    ]

    /// One spelling for two families: Jamendo writes `triphop`, archive.org
    /// writes `trip-hop`, and a human writes `trip hop`. Separators carry no
    /// meaning here, so they are dropped for the LOOKUP — the table keeps the
    /// form each source queries with.
    static func normalizedMusicTerm(_ term: String) -> String {
        term.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let musicAxisNormalized: [String: String] = {
        var out: [String: String] = [:]
        for (term, shelf) in musicAxis { out[normalizedMusicTerm(term)] = shelf }
        return out
    }()

    /// Which shelf does this tag/subject fall on? nil = unknown, never guessed.
    static func musicShelf(forTag tag: String) -> String? {
        musicAxisNormalized[normalizedMusicTerm(tag)]
    }

    /// All tags that fold onto one shelf — the server-side shelf query.
    /// Jamendo's `fuzzytags` speak WITHOUT separators — the hyphenated and
    /// spaced spellings in the table belong to archive.org and would only
    /// lengthen the query here. Capped, because a shelf folds up to
    /// thirty-five terms and an OR-join of all of them is noise, not reach.
    static func musicTags(forShelf shelf: String) -> [String] {
        let own = musicAxis.filter { $0.value == shelf && normalizedMusicTerm($0.key) == $0.key }
            .map(\.key).sorted()
        // The shelf's OWN name leads — an alphabetical cut would have dropped
        // `electronic` from the electronic shelf (8bit … dance fill the eight
        // first), and with it the tag that actually carries the query.
        guard own.contains(shelf) else { return Array(own.prefix(8)) }
        return [shelf] + own.filter { $0 != shelf }.prefix(7)
    }

    /// archive.org `subject:` terms of one shelf — same shape as the book
    /// shelves use, same cap.
    static func musicSubjects(forShelf shelf: String) -> [String] {
        musicAxis.filter { $0.value == shelf }.map(\.key).sorted()
    }

    // MARK: - R1 (09.08.): the shelves ask the SERVER, not a local pool

    /// A shelf → the subject terms for the SUBJECT-based catalogs
    /// (archive.org `subject:`, gutendex `topic=`). Both spelling families
    /// ride along, because a shelf can be reached from either.
    static func subjects(forShelf shelf: String) -> [String] {
        let terms = lcshAxis.filter { $0.value == shelf }.map(\.key)
            + librivoxAxis.filter { $0.value == shelf }.map(\.key)
        return Array(Set(terms)).sorted()
    }

    /// R2: on ONE page a title belongs to exactly one shelf — the first in
    /// browse order. („Eudemian Ethics" carries Philosophy AND Religion; two
    /// identical tiles on one page read as a bug, not as truth.) On the shelf
    /// FULL pages it may legitimately appear in both — there it IS the truth
    /// of its subjects.
    static func primaryShelf(among shelves: [String]) -> String? {
        librivoxShelves.map(\.key).first { shelves.contains($0) }
    }

    /// Gutenberg subjects → shelves, over BOTH spelling families.
    static func shelves(forSubjects subjects: [String]) -> [String] {
        var hit = Set<String>()
        for raw in subjects {
            for part in raw.components(separatedBy: " -- ") {
                let key = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let shelf = librivoxAxis[key] ?? lcshAxis[key] { hit.insert(shelf) }
            }
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
