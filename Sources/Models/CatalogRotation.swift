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
}
