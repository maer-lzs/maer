// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// CONTAINER feeds (the public-broadcast radio-play pools) carry
/// many different works in one feed. "Palmer Eldritch (1/2)", "(2/2)",
/// "Unearthing (1/8)" …. And the plain feed order interleaves them, part 2
/// above part 1. This brings the LIST into work order. Deliberately nothing
/// more: no work cards, no disclosure UI, same list. The reordering makes the
/// familiar episode list readable, it does not add a second navigation level.
///
/// Everything here is pure and conservative: a title without a part pattern
/// is a single piece and keeps its place. A wrong grouping would be worse
/// than none, so the stem match is exact after folding.
nonisolated enum PodcastWorkOrder {
    struct Part: Equatable {
        /// The work's title stem, folded (grouping key).
        let stem: String
        let index: Int
        let total: Int?
    }

    /// Recognized spellings, measured on WDR/BR/hr2/Ö1:
    /// `(1/8)`, `1/8`, `Teil 3`, `Teil 3 von 5`, `Folge 3 von 5`.
    /// The stem is what stands BEFORE the pattern, cut at the usual
    /// separators (bracket, colon, dash) and folded.
    static func part(fromTitle title: String) -> Part? {
        guard let match = numberMatch(in: title) else { return nil }
        let stem = fold(String(title[title.startIndex..<match.start]))
        guard !stem.isEmpty else { return nil }
        return Part(stem: stem, index: match.index, total: match.total)
    }

    private struct NumberMatch {
        let start: String.Index
        let index: Int
        let total: Int?
    }

    private static func numberMatch(in title: String) -> NumberMatch? {
        let patterns: [(String, Bool)] = [
            // n/m. The dominant spelling, with or without brackets.
            ("\\(\\s*(\\d{1,3})\\s*/\\s*(\\d{1,3})\\s*\\)", true),
            ("\\b(\\d{1,3})\\s*/\\s*(\\d{1,3})\\b", true),
            // "Teil 3 von 5" / "Folge 3 von 5"
            ("\\b(?:Teil|Folge)\\s+(\\d{1,3})\\s+von\\s+(\\d{1,3})\\b", true),
            // "Teil 3" / "Folge 3". No total known.
            ("\\b(?:Teil|Folge)\\s+(\\d{1,3})\\b", false),
        ]
        for (pattern, hasTotal) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let full = Range(match.range, in: title),
                  let first = Range(match.range(at: 1), in: title),
                  let index = Int(title[first]), index > 0
            else { continue }
            var total: Int?
            if hasTotal, let second = Range(match.range(at: 2), in: title) {
                total = Int(title[second])
            }
            // A total below the part number is not a part count.
            if let total, total < index { continue }
            return NumberMatch(start: full.lowerBound, index: index, total: total)
        }
        return nil
    }

    /// Stem normalisation: cut at the first hard separator, fold case and
    /// diacritics, drop punctuation. "Mariana Leky: Kummer aller Art" and
    /// "Mariana Leky – Kummer aller Art" must group.
    static func fold(_ raw: String) -> String {
        var text = raw
        for separator in ["(", "[", ":", " – ", " — ", " - "] {
            if let range = text.range(of: separator) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Share of titles carrying a part pattern. The scope dial: the
    /// reordering only kicks in where the feed really IS a container.
    static func partDensity(titles: [String]) -> Double {
        guard !titles.isEmpty else { return 0 }
        return Double(titles.filter { part(fromTitle: $0) != nil }.count) / Double(titles.count)
    }

    /// A feed counts as a container from this share of part-patterned
    /// episodes upward. Reasoning in the report: below that, the pattern is
    /// a coincidence of a few titles and regrouping would move episodes for
    /// no gain; a real container feed sits far above it (the curated pools
    /// measure well past 30 %).
    static let containerThreshold = 0.30

    /// The list in work order: works stay CONTIGUOUS blocks, positioned by
    /// their newest part (so the overall chronology is untouched), parts
    /// ascending INSIDE the work. Single pieces keep their place entirely.
    /// `items` must already be in the caller's chronological order.
    static func ordered<T>(_ items: [T], newestFirst: Bool,
                           title: (T) -> String) -> [T] {
        guard partDensity(titles: items.map(title)) >= containerThreshold else { return items }
        var blockOrder: [String] = []          // stems in first-appearance order
        var blocks: [String: [(offset: Int, item: T)]] = [:]
        var out: [(key: String?, item: T)] = []
        for (offset, item) in items.enumerated() {
            guard let part = part(fromTitle: title(item)) else {
                out.append((nil, item))
                continue
            }
            if blocks[part.stem] == nil {
                blocks[part.stem] = []
                blockOrder.append(part.stem)
                // The block takes the position of its FIRST appearance.
                // Which, in a newest-first list, is its newest part.
                out.append((part.stem, item))
            }
            blocks[part.stem]?.append((offset, item))
        }
        var emitted = Set<String>()
        var result: [T] = []
        for entry in out {
            guard let stem = entry.key else { result.append(entry.item); continue }
            guard emitted.insert(stem).inserted, let block = blocks[stem] else { continue }
            // Inside a work: ascending by part number, ties keep feed order.
            let sorted = block.sorted { a, b in
                let pa = part(fromTitle: title(a.item))?.index ?? 0
                let pb = part(fromTitle: title(b.item))?.index ?? 0
                return pa == pb ? a.offset < b.offset : pa < pb
            }
            result.append(contentsOf: sorted.map(\.item))
        }
        _ = newestFirst   // the caller's sort decides the chronology; blocks follow it
        return result
    }

    /// A row eyebrow repeating the SHOW title is noise.
    /// Suppress it. Pure so every show surface answers it identically.
    static func eyebrow(author: String?, showTitle: String?) -> String? {
        guard let author, !author.isEmpty else { return nil }
        guard let showTitle, !showTitle.isEmpty else { return author }
        return fold(author) == fold(showTitle) ? nil : author
    }
}
