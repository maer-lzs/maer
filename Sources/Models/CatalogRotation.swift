// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The catalog rows always showed the same titles. With
/// `sort=downloads desc` that is structural, because it is the all-time
/// ranking and the all-time ranking does not move.
///
/// The fix is a DAILY ROTATION INSIDE THE QUALITY WINDOW: the sort stays
/// popularity, but which PAGE the row shows is derived from the date. Three
/// properties come out of that, and each one is why it is not plain random:
///  * **stable within the day**. The row does not jump on scroll, tab switch
///    or return (a row that reshuffles under the finger reads as a bug),
///  * **reproducible**. With a finding we know what was on screen,
///  * **quality preserved**. Popularity filters broken metadata and uploader
///    noise better than any heuristic of ours.
///
/// The RANDOM BUTTON is a different gesture and keeps a different meaning:
/// it draws from the WHOLE stock (`sort=random`). Row = today's pick from the
/// good part; button = anything at all. Two gestures, two meanings.
nonisolated enum CatalogRotation {
    /// Share of the stock the rotation window covers. The top tenth is
    /// still comfortably "popular", and it is wide enough that a row looks
    /// different every day for months.
    static let windowShare = 10

    /// Days since a fixed epoch, in UTC. Injectable date, because a rule that
    /// depends on "today" is otherwise untestable. And because the harness
    /// must be able to pin a day.
    static func dayIndex(on date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// The page a popularity row shows today.
    ///
    /// `total` is the MEASURED stock of that surface (dated in the caller.
    /// Drift of a few percent only shifts the window slightly). A stock too
    /// small for a second page keeps page 1: rotating a tiny curated surface
    /// would only shuffle the same items.
    static func page(total: Int, rowSize: Int, on date: Date) -> Int {
        page(total: total, rowSize: rowSize, on: date, salt: 0)
    }

    /// Neighbouring shelves began with exactly the same tiles, because every
    /// shelf asks its source with the same sorting, page 1. A title carrying
    /// two shelves therefore stands on top in BOTH. The overlap is correct in
    /// substance; only showing the same EXCERPT twice is wrong.
    ///
    /// With the shelf key in the seed they reach into different places of
    /// their stock. And because only the DAY moves the page, the mixture
    /// stays stable within the day: a row that re-sorts under the fingers is
    /// a layout jump in slow motion.
    static func page(total: Int, rowSize: Int, on date: Date, salt: Int) -> Int {
        guard total > 0, rowSize > 0 else { return 1 }
        let window = total / windowShare
        let pages = window / rowSize
        guard pages > 1 else { return 1 }
        return 1 + ((dayIndex(on: date) &+ salt) % pages)
    }

    /// A stable seed derived from the shelf name and independent of the
    /// source text. `hashValue` would be salted per process, making the
    /// mixture different on every launch, the same consideration as for the
    /// session seed of the mixed rows.
    static func salt(forShelf shelf: String) -> Int {
        shelf.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }

    /// A title may stand in two shelves, because it belongs in both, but not
    /// as a TWIN directly below itself. What already stood higher up on this
    /// page sorts to the back here. It EMPTIES no shelf: a move to the back
    /// and never a discard.
    ///
    /// "Higher up" means the BROWSE ORDER of the page, not the order the
    /// answers happen to arrive in. Decided per arrival, the rule made the
    /// same shelf come out differently on two passes of the same day,
    /// because a task group finishes in whatever order it finishes. The
    /// daily mixture has to be stable within the day, so the rule may only
    /// depend on things that are. Lives HERE beside the shelf salt because
    /// the two are one answer: the salt spreads the excerpts, this rule
    /// catches the overlap the salt cannot avoid. Every shelf page calls
    /// it; a surface with its own loading door must not skip it.
    static func twinFree(_ stock: [String: [LibraryItem]],
                         order: [String], previewLimit: Int) -> [String: [LibraryItem]] {
        var out = stock
        var oben: Set<String> = []
        for key in order {
            guard let items = out[key], !items.isEmpty else { continue }
            let frisch = items.filter { !oben.contains($0.id) }
            let zwillinge = items.filter { oben.contains($0.id) }
            let sortiert = frisch + zwillinge
            out[key] = sortiert
            oben.formUnion(sortiert.prefix(previewLimit).map(\.id))
        }
        return out
    }

    /// The same rule for the surfaces that carry the measured total beside
    /// the items; only the items are reordered, the totals stay.
    static func twinFree(_ stock: [String: (items: [LibraryItem], total: Int?)],
                         order: [String], previewLimit: Int)
        -> [String: (items: [LibraryItem], total: Int?)] {
        let sortiert = twinFree(stock.mapValues(\.items),
                                order: order, previewLimit: previewLimit)
        return stock.reduce(into: [:]) { out, entry in
            out[entry.key] = (sortiert[entry.key] ?? entry.value.items, entry.value.total)
        }
    }
}
