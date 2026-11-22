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

    /// The composer: the name before the dash of the title, as the file
    /// names of the collection put it, else the artist field the source
    /// states, which names the performers as often. Either counts only
    /// where it reads as a name. Accents and case do not count; no name
    /// gives an empty key.
    static func composerKey(author: String?, title: String) -> String {
        var key = ""
        if let dash = title.range(of: " - ") { key = familyName(String(title[..<dash.lowerBound])) }
        if key.isEmpty { key = familyName(author ?? "") }
        return folded(key)
    }

    /// The family name of a name: "Composer:" and a bracketed rest fall
    /// away; four words at most, no digit, no word of a performer or a
    /// work; else none.
    private static func familyName(_ raw: String) -> String {
        var name = raw
        if let bracket = name.firstIndex(of: "(") { name = String(name[..<bracket]) }
        if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = name.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".;")) }
        guard !words.isEmpty, words.count <= 4, !name.contains(where: \.isNumber),
              !words.contains(where: notNameWords.contains),
              !name.lowercased().contains("unknown") else { return "" }
        return MusopenCoverArt.familyName(name)
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
