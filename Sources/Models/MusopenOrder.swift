// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The order of the Musopen page: by composer, then by work; the single
/// parts of an orchestra recording (one instrument or one microphone, as
/// "1st violin B 02" or "Decca 03 C") at the end.
nonisolated enum MusopenOrder {
    /// The first word of a single part: an instrument of the orchestra or
    /// a microphone position of the recording.
    static let partWords: Set<String> = [
        "violin", "viola", "celli", "cello", "db", "bassoon", "basson", "contra", "clarinet",
        "flute", "horn", "oboe", "timpani", "trumpet", "trombone", "tuba", "harp",
        "decca", "premix", "surr", "wide",
    ]

    /// A short name without a dash, with a number, whose first word (after
    /// an ordinal such as "1st") is an instrument or a microphone.
    static func isSinglePart(_ title: String) -> Bool {
        guard !title.contains(" - "), title.contains(where: \.isNumber) else { return false }
        var words = title.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count <= 5 else { return false }
        if let first = words.first, first.first?.isNumber == true,
           ["st", "nd", "rd", "th"].contains(where: first.hasSuffix) {
            words.removeFirst()
        }
        return words.first.map(partWords.contains) ?? false
    }

    /// Words that tell a performer, a work or a sentence from a name.
    static let notNameWords: Set<String> = [
        "orchestra", "archive", "archives", "musopen", "unknown", "quartet", "ensemble", "symphony",
        "choir", "trio", "band", "philharmonic", "by", "author", "no", "op", "minor", "major", "sonata",
        "concerto", "suite", "prelude", "nocturne", "waltz", "etude", "overture", "mazurka", "in", "of", "the",
    ]

    /// The order's key: the family name of the composer (`composer`).
    /// Accents and case do not count; no name gives an empty key.
    static func composerKey(author: String?, title: String) -> String {
        folded(MusopenCoverArt.familyName(composer(author: author, title: title)))
    }

    /// The composer, the one answer the order, the drawn cover (its colour
    /// and letter) and the player ask. The name before the dash of the
    /// title, as the file names of the collection put it, decides who;
    /// where the artist field names the same family, its fuller spelling
    /// shows ("Johann Sebastian Bach" over "Bach, J S"). Without a name
    /// before the dash the field speaks, which names the performers as
    /// often. Either counts only where it reads as a name; "Family, Given"
    /// shows as it is spoken.
    ///
    /// A known work whose files name no composer anywhere (Commons names
    /// only the uploader for "La Traviata") takes its composer from
    /// `knownWorks`; "Family, Work" counts as a name before the work only
    /// for a family of the stock (`stockComposers`), so "Komm, süsser Tod"
    /// names nobody.
    static func composer(author: String?, title: String) -> String? {
        if let known = knownWorks.first(where: { folded(title).contains($0.key) })?.value { return known }
        let field = readableName(author ?? "").map(spoken)
        guard let named = namedBefore(title)?.name else { return field }
        let fromTitle = spoken(named)
        let sameFamily = field.map { folded(MusopenCoverArt.familyName($0)) == folded(MusopenCoverArt.familyName(fromTitle)) }
        return sameFamily == true ? field : fromTitle
    }

    /// The name that stands before the work in a title, with the rest: the
    /// name before " - ", or before ", " where its family is one of the
    /// stock's composers.
    private static func namedBefore(_ title: String) -> (name: String, work: String)? {
        if let dash = title.range(of: " - "), let named = readableName(String(title[..<dash.lowerBound])) {
            return (named, String(title[dash.upperBound...]))
        }
        if let comma = title.range(of: ", "), let named = readableName(String(title[..<comma.lowerBound])),
           stockFamilies.contains(folded(MusopenCoverArt.familyName(spoken(named)))) {
            return (named, String(title[comma.upperBound...]))
        }
        return nil
    }

    /// Composer, work and performer of a recording, the one answer for the
    /// tile, the drawn cover, the page and the player: the composer as
    /// `composer` says; the work the title without the composer in front
    /// of it (the cover names him above); the performer the artist field
    /// where it names someone else.
    static func parts(author: String?, title: String) -> (composer: String?, work: String, performer: String?) {
        let composer = composer(author: author, title: title)
        var work = title
        if let named = namedBefore(title), let composer,
           folded(MusopenCoverArt.familyName(spoken(named.name))) == folded(MusopenCoverArt.familyName(composer)) {
            work = named.work.trimmingCharacters(in: .whitespaces)
        }
        // The field as it stands, an ensemble too, unless it names the composer.
        let field = (author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let namesComposer = readableName(field).map(spoken).map { name in
            composer.map { folded(MusopenCoverArt.familyName($0)) == folded(MusopenCoverArt.familyName(name)) } == true
        } ?? false
        let performer = field.isEmpty || namesComposer ? nil : field
        return (composer, work.isEmpty ? title : work, performer)
    }

    /// Works whose files name their composer nowhere: neither the artist
    /// field (the uploader) nor the file name. Measured on Commons 24.11.2026.
    static let knownWorks: [String: String] = ["la traviata": "Giuseppe Verdi"]

    /// The composers of the stock (55 counted on 23.11.2026), as the source
    /// names them; their families let "Family, Work" stand as a name.
    static let stockComposers = [
        "Ludwig van Beethoven", "Johann Sebastian Bach", "Wolfgang Amadeus Mozart", "Frédéric Chopin",
        "Johannes Brahms", "Franz Schubert", "Antonín Dvořák", "Pyotr Ilyich Tchaikovsky", "Giuseppe Verdi",
        "Felix Mendelssohn", "Robert Schumann", "Franz Liszt", "Claude Debussy", "Edvard Grieg", "Joseph Haydn",
        "George Frideric Handel", "Antonio Vivaldi", "Erik Satie", "Sergei Rachmaninoff", "Modest Mussorgsky",
        "Richard Wagner", "Gioachino Rossini", "Giacomo Puccini", "Georges Bizet", "Camille Saint-Saëns",
        "Maurice Ravel", "Edward Elgar", "Gustav Holst", "Johann Strauss", "Johann Pachelbel", "Isaac Albeniz",
        "Gabriel Fauré", "Bedřich Smetana", "Jean Sibelius", "Gustav Mahler", "Anton Bruckner", "Hector Berlioz",
        "Carl Maria von Weber", "Niccolò Paganini", "Domenico Scarlatti", "Arcangelo Corelli", "Henry Purcell",
        "Georg Philipp Telemann", "Christoph Willibald Gluck", "Luigi Boccherini", "Muzio Clementi",
        "Nikolai Rimsky-Korsakov", "Alexander Borodin", "Enrique Granados", "Manuel de Falla", "Scott Joplin",
        "Gaetano Donizetti", "Vincenzo Bellini", "Jacques Offenbach", "Charles Gounod",
    ]

    private static let stockFamilies = Set(stockComposers.map { folded(MusopenCoverArt.familyName($0)) })

    /// The line under the title in the player, the mini player and the lock
    /// screen: for a Musopen recording its composer (`composer`), else what
    /// the source states; another source keeps its own line.
    static func artistLine(itemId: String, title: String?, author: String?) -> String? {
        guard MusopenCoverArt.applies(to: itemId) else { return author }
        return composer(author: author, title: title ?? "") ?? author
    }

    /// The labels under which a field names the composer.
    static let composerLabels: Set<String> = ["composer", "author"]

    /// A name as the source writes it, if it reads as one. The field may
    /// hold several parts (split at a semicolon or a line); the first part
    /// that is not labelled as something else decides. A label "Composer:"
    /// or "Author:" falls away, any other label ("Performer:") rules the
    /// part out, as does "(performer)"; a bracketed rest falls away. Four
    /// words at most, no digit, no word of a performer or a work; else nil.
    private static func readableName(_ raw: String) -> String? {
        for part in raw.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            var name = String(part)
            if let colon = name.firstIndex(of: ":") {
                let label = name[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard composerLabels.contains(label) else { continue }
                name = String(name[name.index(after: colon)...])
            }
            guard !name.lowercased().contains("(performer") else { continue }
            if let bracket = name.firstIndex(of: "(") { name = String(name[..<bracket]) }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let words = name.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".;")) }
            guard words.count <= 4, !name.contains(where: \.isNumber),
                  !words.contains(where: notNameWords.contains),
                  !name.lowercased().contains("unknown") else { return nil }
            return name
        }
        return nil
    }

    /// "Bach, J S" as it is spoken: "J S Bach".
    private static func spoken(_ name: String) -> String {
        guard let comma = name.firstIndex(of: ",") else { return name }
        let family = name[..<comma].trimmingCharacters(in: .whitespaces)
        let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return given.isEmpty ? family : given + " " + family
    }

    /// Named composers first, then the recordings without one, then the
    /// single parts; within each, by composer and work.
    static func ordered<T>(_ items: [T], title: (T) -> String, composer: (T) -> String?) -> [T] {
        let keyed = items.map { item -> (rank: Int, composer: String, work: String, item: T) in
            let name = title(item)
            let key = composerKey(author: composer(item), title: name)
            let rank = isSinglePart(name) ? 2 : (key.isEmpty ? 1 : 0)
            return (rank, key, folded(name), item)
        }
        return keyed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.composer != b.composer { return a.composer < b.composer }
            return a.work < b.work
        }.map(\.item)
    }

    /// The work a movement belongs to: the title before its last " - "
    /// when what follows starts with the movement's number ("IV. Allegro",
    /// "2. Andante"); nil for a title that names no movement.
    static func workStem(_ title: String) -> String? {
        guard let dash = title.range(of: " - ", options: .backwards) else { return nil }
        let movement = title[dash.upperBound...]
        guard movement.range(of: #"^([IVXLC]+|[0-9]+)[.)] "#, options: .regularExpression) != nil else { return nil }
        let stem = folded(String(title[..<dash.lowerBound])).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? nil : stem
    }

    static func movementNumber(_ title: String) -> Int? {
        nil
    }

    /// The next movement of the same work after a recording: the same
    /// composer, performer and work, in the order of the page (`ordered`);
    /// nil after the last movement and for a title without movements.
    static func nextMovement<T>(after id: String, in items: [T], id key: (T) -> String, title: (T) -> String,
                                composer: (T) -> String?, performer: (T) -> String?) -> T? {
        guard let finished = items.first(where: { key($0) == id }), let stem = workStem(title(finished)) else { return nil }
        func sameWork(_ item: T) -> Bool {
            workStem(title(item)) == stem
                && composerKey(author: composer(item), title: title(item)) == composerKey(author: composer(finished), title: title(finished))
                && performer(item) == performer(finished)
        }
        let page = ordered(items.filter(sameWork), title: title, composer: composer)
        guard let at = page.firstIndex(where: { key($0) == id }), at + 1 < page.count else { return nil }
        return page[at + 1]
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
