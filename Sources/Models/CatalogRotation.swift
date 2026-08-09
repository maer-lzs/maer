// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Auftrag 09.08.: the catalog rows always showed the same titles — with
/// `sort=downloads desc` that is structural, because it is the all-time
/// ranking and the all-time ranking does not move.
///
/// The fix is a DAILY ROTATION INSIDE THE QUALITY WINDOW: the sort stays
/// popularity, but which PAGE the row shows is derived from the date. Three
/// properties come out of that, and each one is why it is not plain random:
///  * **stable within the day** — the row does not jump on scroll, tab switch
///    or return (a row that reshuffles under the finger reads as a bug),
///  * **reproducible** — with a finding we know what was on screen,
///  * **quality preserved** — popularity filters broken metadata and uploader
///    noise better than any heuristic of ours.
///
/// The RANDOM BUTTON is a different gesture and keeps a different meaning:
/// it draws from the WHOLE stock (`sort=random`). Row = today's pick from the
/// good part; button = anything at all. Two gestures, two meanings.
nonisolated enum CatalogRotation {
    /// Share of the stock the rotation window covers — the top tenth is
    /// still comfortably "popular", and it is wide enough that a row looks
    /// different every day for months.
    static let windowShare = 10

    /// Days since a fixed epoch, in UTC. Injectable date, because a rule that
    /// depends on "today" is otherwise untestable — and because the harness
    /// must be able to pin a day.
    static func dayIndex(on date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// The page a popularity row shows today.
    ///
    /// `total` is the MEASURED stock of that surface (dated in the caller —
    /// drift of a few percent only shifts the window slightly). A stock too
    /// small for a second page keeps page 1: rotating a tiny curated surface
    /// would only shuffle the same items.
    static func page(total: Int, rowSize: Int, on date: Date) -> Int {
        guard total > 0, rowSize > 0 else { return 1 }
        let window = total / windowShare
        let pages = window / rowSize
        guard pages > 1 else { return 1 }
        return 1 + (dayIndex(on: date) % pages)
    }
}
