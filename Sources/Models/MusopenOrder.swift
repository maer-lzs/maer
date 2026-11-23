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
    static func composer(author: String?, title: String) -> String? {
        let field = readableName(author ?? "").map(spoken)
        guard let dash = title.range(of: " - "), let named = readableName(String(title[..<dash.lowerBound])) else {
            return field
        }
        let fromTitle = spoken(named)
        let sameFamily = field.map { folded(MusopenCoverArt.familyName($0)) == folded(MusopenCoverArt.familyName(fromTitle)) }
        return sameFamily == true ? field : fromTitle
    }

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

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
