// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The genre axes of the two catalog pages. Radio plays (podcast
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
    ///   radio play. Including it would fill the chip with the wrong thing.
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
        // The measured new shelves (IA religion, OTR western + variety).
        ("religion", String(localized: "Religion")),
        ("western", String(localized: "Western")),
        ("music", String(localized: "Music & Variety")),
    ]

    /// Gutenberg LCSH subjects → the SAME shelves: one axis, extended. No
    /// GutenbergGenreAxis next to it. The measurement of the 1,124 audio
    /// titles drove the entries (Domestic fiction 15 · Love
    /// stories 15 · Adventure stories 13 · Bildungsromans 9 · Satire 6 ·
    /// Historical fiction 5); four of them already sat in librivoxAxis
    /// verbatim. LCSH facets ("England -- Fiction") are split and each half
    /// tried. The qualifier carries the genre.
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
        // Full-stock measurement over 4,257 IA titles (26 % shelve): the IA
        // subjects speak plainly; philosophy/poetry already
        // map via librivoxAxis, religion is a NEW shelf (80 titles).
        "religion": "religion",
        "christianity": "religion",
        "bible": "religion",
        "theology": "religion",
        // Full-stock measurement over 2,314 OTR bundles (40 % shelve): plain
        // OTR subject terms; suspense counts into the horror
        // shelf (the Horror/Suspense 114 is ONE shelf), western and
        // music/variety are NEW shelves (82 / 159 bundles).
        "crime": "crime",
        // Exact terms like all the others, never a substring.
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

    /// Measured over 200 popular tracks (93 % carry tags, the best axis of
    /// all sources): the MUSIC genre family. Related tags fold
    /// onto their parent shelf as AXIS entries (electropop→pop), no special
    /// code; netlabels inherits this axis later. Server-side use: the shelf
    /// query sends ALL its tags (fuzzytags OR-join) via `musicTags(forShelf:)`.
    /// The folded axis: small pots fold into large ones, capped at about
    /// thirty shelves. Two spelling families ride in ONE table. Jamendo writes its tags without separators
    /// (`electropop`, `singersongwriter`), archive.org subjects use spaces and
    /// hyphens (`trip-hop`, `drum and bass`). Lookup normalises both sides, so
    /// each term is listed ONCE, in the form the SOURCE queries with.
    ///
    /// Measured before building (1.000 netlabel titles, 200 Jamendo tracks):
    /// the old 14-term axis covered 36,0 % of netlabels and 81,0 % of Jamendo.
    /// The ceiling is what carries terms at all. 93,5 % / 98,0 %.
    static let musicAxis: [String: String] = [
        // electronic. The big fold: every club and machine sub-genre
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
        // gothic. Measured as its own family in the netlabel stock
        "gothic": "gothic", "industrial": "gothic", "darkwave": "gothic",
        "coldwave": "gothic", "minimal wave": "gothic", "goth": "gothic",
    ]

    /// The browse-everything shelf of the archive audiobooks: 84 % of
    /// that collection carries no subjects (measured), so no genre shelf
    /// can ever reach it. This one makes the WHOLE stock reachable without
    /// a genre claim; a title without subjects lives here and nowhere else.
    static let browseAllKey = "browseAll"
    static let browseAllTitle = String(localized: "Browse Everything")

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
    /// meaning here, so they are dropped for the LOOKUP. The table keeps the
    /// form each source queries with.
    static func normalizedMusicTerm(_ term: String) -> String {
        term.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// All tags that fold onto one shelf. The server-side shelf query.
    /// Jamendo's `fuzzytags` speak WITHOUT separators. The hyphenated and
    /// spaced spellings in the table belong to archive.org and would only
    /// lengthen the query here. Capped, because a shelf folds up to
    /// thirty-five terms and an OR-join of all of them is noise, not reach.
    static func musicTags(forShelf shelf: String) -> [String] {
        let own = musicAxis.filter { $0.value == shelf && normalizedMusicTerm($0.key) == $0.key }
            .map(\.key).sorted()
        // The shelf's OWN name leads. An alphabetical cut would have dropped
        // `electronic` from the electronic shelf (8bit … dance fill the eight
        // first), and with it the tag that actually carries the query.
        guard own.contains(shelf) else { return Array(own.prefix(8)) }
        return [shelf] + own.filter { $0 != shelf }.prefix(7)
    }

    /// archive.org `subject:` terms of one shelf. Same shape as the book
    /// shelves use, same cap.
    static func musicSubjects(forShelf shelf: String) -> [String] {
        musicAxis.filter { $0.value == shelf }.map(\.key).sorted()
    }

    // MARK: - The shelves ask the SERVER, not a local pool

    /// How rich each term is in gutendex's audiobook stock. The number lives
    /// here as data, because the term selection needs it and the app cannot
    /// measure it at runtime.
    ///
    /// A term without an entry counts as 0 and sorts behind every measured
    /// one, never in front of them.
    static let measuredGutenbergYield: [String: Int] = [
        "fiction": 503,
        "poetry": 111,
        "music": 99,
        "children": 97,
        "history": 87,
        "adventure": 67,
        "adventure stories": 62,
        "science fiction": 58,
        "juvenile fiction": 51,
        "short stories": 50,
        "mystery": 48,
        "detective": 47,
        "detective and mystery stories": 46,
        "bible": 45,
        "children's literature": 39,
        "love stories": 38,
        "humorous stories": 35,
        "fairy tales": 31,
        "historical fiction": 31,
        "domestic fiction": 30,
        "satire": 26,
        "bildungsromans": 23,
        "horror": 23,
        "horror tales": 23,
        "sea stories": 22,
        "children's stories": 18,
        "drama": 16,
        "detective fiction": 14,
        "biography": 13,
        "philosophy": 13,
        "war stories": 12,
        "ghost stories": 9,
        "folklore": 8,
        "epistolary fiction": 7,
        "romance": 6,
        "christianity": 5,
        "gothic fiction": 5,
        "comedy": 4,
        "crime": 4,
        "plays": 4,
        "religion": 3,
        "children's fiction": 2,
        "western": 2,
        "musical": 1,
        "action & adventure fiction": 0,
        "autobiography": 0,
        "biography & autobiography": 0,
        "crime & mystery fiction": 0,
        "crime drama": 0,
        "fantastic fiction": 0,
        "general fiction": 0,
        "horror & supernatural fiction": 0,
        "humorous fiction": 0,
        "literary fiction": 0,
        "memoirs": 0,
        "myths, legends & fairy tales": 0,
        "nautical & marine fiction": 0,
        "sci-fi": 0,
        "single author collections": 0,
        "suspense": 0,
        "theology": 0,
        "thriller": 0,
        "variety": 0,
        "westerns": 0,
    ]

    /// A shelf → the subject terms for the SUBJECT-based catalogs
    /// (archive.org `subject:`, gutendex `topic=`). Both spelling families
    /// ride along, because a shelf can be reached from either.
    ///
    /// Sorted by measured richness rather than alphabetically: whoever cuts
    /// the list then cuts the weakest terms instead of the strongest. The
    /// archive.org branch does not cut at all.
    static func subjects(forShelf shelf: String) -> [String] {
        let terms = lcshAxis.filter { $0.value == shelf }.map(\.key)
            + librivoxAxis.filter { $0.value == shelf }.map(\.key)
        return Array(Set(terms)).sorted {
            let left = measuredGutenbergYield[$0] ?? 0
            let right = measuredGutenbergYield[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
    }

    /// The ONE normalisation of a subject line, shared by BOTH assignment
    /// paths. Two half normalisations used to live side by side (the shelf
    /// count split on ";" and "," but not the LCSH facet " -- "; the tile
    /// classification split the facet but not the comma), so the same
    /// title counted on one surface and not on the other. Splits on all
    /// three separators, each part compared WHOLE and case-folded, never
    /// a substring (the class that once put a didactic drama into the
    /// crime shelf).
    nonisolated static func normalizedParts(_ subject: String) -> [String] {
        subject.lowercased()
            .replacingOccurrences(of: " -- ", with: ";")
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Gutenberg subjects → shelves, over BOTH spelling families.
    static func shelves(forSubjects subjects: [String]) -> [String] {
        var hit = Set<String>()
        for raw in subjects {
            for key in normalizedParts(raw) {
                if let shelf = librivoxAxis[key] ?? lcshAxis[key] { hit.insert(shelf) }
            }
        }
        return librivoxShelves.map(\.key).filter(hit.contains)
    }

    // MARK: - The decade axis for Old Time Radio

    /// The decades Old Time Radio is divided by. They stand BESIDE the
    /// genres rather than in their place: an item has both.
    static let decadeShelves: [(key: String, title: String)] = [
        ("1930s", "1930er"), ("1940s", "1940er"),
        ("1950s", "1950er"), ("1960s", "1960er"),
    ]

    /// A single year folds onto its decade, an already folded statement
    /// stays. Assigned positively: whatever names no year drops out instead
    /// of landing in a catch-all shelf, the same rule as for the genres.
    static func decade(forSubject subject: String) -> String? {
        let term = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An already folded statement stays as it is.
        if term.range(of: #"^19[0-9]0s$"#, options: .regularExpression) != nil { return term }
        guard let year = term.range(of: #"^(19[0-9]{2})$"#, options: .regularExpression)
            .flatMap({ Int(term[$0]) }) else { return nil }
        return "\(year / 10 * 10)s"
    }

    /// Which decades does this entry carry? More than one is possible (a
    /// series runs across the turn), de-duplicated, in browse order.
    static func decades(forSubjects subjects: [String]) -> [String] {
        var hit = Set<String>()
        for raw in subjects {
            for part in raw.components(separatedBy: " -- ") {
                if let decade = decade(forSubject: part) { hit.insert(decade) }
            }
        }
        return decadeShelves.map(\.key).filter(hit.contains)
    }
}
