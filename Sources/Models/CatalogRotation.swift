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
        page(total: total, rowSize: rowSize, on: date, salt: 0)
    }

    /// R57 (the owner am Geraet: „Geschichte · 1609" und „Biografien · 570"
    /// beginnen mit exakt denselben zwei Kacheln — ENTSCHEID: taeglich
    /// durchmischen). Jedes Fach fragt seine Quelle mit derselben Sortierung,
    /// Seite 1 — ein Titel, der zwei Faecher traegt, steht also in BEIDEN
    /// oben. Die Ueberschneidung ist inhaltlich richtig; falsch ist nur, dass
    /// beide denselben AUSSCHNITT zeigen.
    ///
    /// Mit dem Fach-Schluessel im Startwert greifen sie an verschiedenen
    /// Stellen ihres Bestands — und weil nur der TAG die Seite bewegt, bleibt
    /// die Mischung innerhalb des Tages stabil (Invariante 2: eine Reihe, die
    /// sich unter den Fingern umsortiert, ist ein Layout-Sprung in Zeitlupe).
    static func page(total: Int, rowSize: Int, on date: Date, salt: Int) -> Int {
        guard total > 0, rowSize > 0 else { return 1 }
        let window = total / windowShare
        let pages = window / rowSize
        guard pages > 1 else { return 1 }
        return 1 + ((dayIndex(on: date) &+ salt) % pages)
    }

    /// Ein stabiler, quelltext-unabhaengiger Startwert aus dem Fach-Namen —
    /// `hashValue` waere je Prozess gesalzen und die Mischung damit bei jedem
    /// Start eine andere (dieselbe Ueberlegung wie beim Sitzungs-Startwert
    /// der Mischreihen).
    static func salt(forShelf shelf: String) -> Int {
        shelf.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}
