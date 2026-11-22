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

    /// The family name the source states; where it states none or only a
    /// note in brackets, the name before the dash of the title. "Composer:"
    /// and a bracketed rest fall away; accents and case do not count.
    static func composerKey(author: String?, title: String) -> String {
        var name = (author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("(") { name = "" }
        if let bracket = name.firstIndex(of: "(") { name = String(name[..<bracket]) }
        if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let dash = title.range(of: " - ") {
            name = String(title[..<dash.lowerBound])
        }
        return folded(MusopenCoverArt.familyName(name))
    }

    static func ordered<T>(_ items: [T], title: (T) -> String, composer: (T) -> String?) -> [T] {
        let keyed = items.map { item -> (part: Bool, composer: String, work: String, item: T) in
            let name = title(item)
            return (isSinglePart(name), composerKey(author: composer(item), title: name), folded(name), item)
        }
        return keyed.sorted { a, b in
            if a.part != b.part { return !a.part }
            if a.composer != b.composer { return a.composer < b.composer }
            return a.work < b.work
        }.map(\.item)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
