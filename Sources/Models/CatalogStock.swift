// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One entry of a kept catalogue stock. Deliberately narrow: what a tile
/// shows and what the shelf assignment asks, nothing else.
///
/// Measured before it was cut this way: the fields cost 259-322 B per entry
/// across the five collections, and the subjects are 13 % of that. Dropping
/// them would have saved almost nothing and destroyed the shelf assignment,
/// so they stay.
nonisolated struct CatalogStockEntry: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var creator: String?
    var subjects: [String]
    /// The popularity the source stated when the stock was taken. It ages,
    /// which is why the ordering of a row is not taken from here alone.
    var downloads: Int?
    /// The stated licence. Absent means absent: the capsule says "rights
    /// not stated" and the download path stays closed. Never guessed.
    var licenseurl: String?
    var year: String?
}

/// A whole collection, as kept. The stock is DERIVED data: it can be thrown
/// away at any time and the app still works through the day store and the
/// placeholder, which stay the fallback rather than becoming dead code.
nonisolated struct CatalogStock: Codable, Sendable {
    /// Which collection this is (`librivoxaudio`, `georgeblood`, …). The
    /// same surface key the day store files its answers under.
    var surface: String
    /// When the stock was taken, seconds since epoch. The refresh rule reads
    /// it; nothing else does.
    var takenAt: Double
    /// The newest source marker seen, so the next fetch asks for what came
    /// after it instead of pulling everything again.
    var watermark: String?
    var entries: [CatalogStockEntry]

    /// Popularity that the stock's own source does not state, gathered
    /// separately. The Gutenberg dump carries no download counts, so the
    /// order of a shelf would have to be invented without this.
    ///
    /// OPTIONAL, and that is not decoration: a non-optional field added
    /// later makes the synthesised decoder THROW on every stock already on
    /// a device, and the read site would quietly see "no stock at all".
    var popularity: [String: Int]?
    /// How far the enumeration got. It runs page by page and may be
    /// interrupted at any time; the next run continues here instead of
    /// starting over.
    var popularityPage: Int?
    /// Where the FIRST fetch stood when it was interrupted. The scrape
    /// cursor is a resumable position, so an app switch costs the last
    /// slice and never the run.
    var fetchCursor: String?
    /// Whether the enumeration reached the end. Until then a shelf keeps
    /// asking the service, because a PARTIAL ranking would silently order a
    /// shelf by "what we happened to have fetched".
    var popularityComplete: Bool?

    /// The popularity of an entry, whoever knows it. The stock's own field
    /// first, because a source that states it is the better witness.
    func downloads(of entry: CatalogStockEntry) -> Int? {
        entry.downloads ?? popularity?[entry.id]
    }
}

/// The rules over a stock. Pure, so they are testable without a network and
/// without a disk.
nonisolated enum CatalogStockRules {
    /// Does this entry belong on that shelf? EXACTLY, never as a substring.
    ///
    /// The substring form is what once put a didactic drama into the crime
    /// shelf, and moving the assignment from the server into the app is
    /// exactly the moment that class could come back. It does not: the
    /// comparison is over whole terms, case-folded.
    static func belongs(_ entry: CatalogStockEntry, toShelfTerms terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let wanted = Set(terms.map { $0.lowercased() })
        for subject in entry.subjects {
            // A subject line can carry several terms separated the way the
            // source separates them. Each PART is compared whole.
            for part in subject.lowercased().split(whereSeparator: { $0 == ";" || $0 == "," }) {
                if wanted.contains(part.trimmingCharacters(in: .whitespaces)) { return true }
            }
            if wanted.contains(subject.lowercased()) { return true }
        }
        return false
    }

    /// Merge a freshly fetched slice into the kept stock.
    ///
    /// **A failed fetch never reaches this**, and an EMPTY one may not empty
    /// the stock: that is the class where a generator exited cleanly and
    /// left a dead data file behind. An empty slice therefore keeps
    /// everything and only moves the timestamp.
    static func merged(_ kept: [CatalogStockEntry],
                       with fresh: [CatalogStockEntry]) -> [CatalogStockEntry] {
        guard !fresh.isEmpty else { return kept }
        var byId = Dictionary(kept.map { ($0.id, $0) }) { first, _ in first }
        for entry in fresh { byId[entry.id] = entry }
        return Array(byId.values).sorted { $0.id < $1.id }
    }

    /// Is the kept stock old enough to ask for what is new? Bound to the
    /// same day change as the rotation and the day store, so there is one
    /// clock and not three.
    static func needsRefresh(_ stock: CatalogStock, now: Date = Date()) -> Bool {
        CatalogRotation.dayIndex(on: Date(timeIntervalSince1970: stock.takenAt))
            < CatalogRotation.dayIndex(on: now)
    }

    /// How many days a stock may live before it is fetched WHOLE again.
    /// The download counts drift slowly, and the daily run only adds what is
    /// new, so nothing would ever correct them.
    static let fullRefetchDays = 30

    /// Time for a full re-fetch? Same clock as everything else, counted in
    /// day changes rather than in a rolling span.
    static func needsFullRefetch(_ stock: CatalogStock, now: Date = Date()) -> Bool {
        let taken = CatalogRotation.dayIndex(on: Date(timeIntervalSince1970: stock.takenAt))
        return CatalogRotation.dayIndex(on: now) - taken >= fullRefetchDays
    }
}
