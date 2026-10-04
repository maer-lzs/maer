// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a store knows about its rows before a write, and the one rule that
/// follows from it. The base advances ONLY after a write landed: a failed
/// write leaves it where it was, so the next write diffs against the last
/// state that really is in the rows. A start that could not read every row
/// leaves the rows unknown and keeps what it did read: a write then removes
/// a row it read and that is gone from the stock, and never removes a row
/// nobody could read. It does not protect such a row from being written
/// over: a write that carries the same key replaces it.
nonisolated enum RowBase<Value> {
    /// The rows as the last landed write or the successful start read left them.
    case known(Value)
    /// The start read succeeded and found no rows: the first write is the
    /// diff against nothing (every row an upsert, the table was empty).
    case fresh
    /// The start read could not read every row. `seen` is what it did read,
    /// nil when the read failed as a whole: the rows may hold anything else.
    case unknown(seen: Value?)

    /// A whole replace is not a plan: it belongs to the migration paths
    /// alone. Without a known base a write upserts, and removes only rows
    /// the start read (`removeSeen`), never one nobody could read.
    enum Plan: Equatable, Sendable {
        case diff
        case upsertOnly
        case removeSeen
    }

    var plan: Plan {
        switch self {
        case .known: return .diff
        case .fresh, .unknown(seen: nil): return .upsertOnly
        case .unknown: return .removeSeen
        }
    }

    /// The base after the start read. Rows that were there but did not
    /// decode make the rows UNKNOWN, never fresh: a later version that
    /// changed the shape must not have its first write remove what it
    /// could not read. `rows` is nil when nothing decoded.
    static func afterLoad(rows: Value?, skipped: Int) -> RowBase<Value> {
        if skipped > 0 { return .unknown(seen: rows) }
        guard let rows else { return .fresh }
        return .known(rows)
    }

    var knownValue: Value? {
        if case .known(let value) = self { return value }
        return nil
    }

    /// The rows a write may remove: the known rows, or without a known base
    /// the rows the start read. The ONE measure of a removal and of the
    /// wipe guard.
    var removable: Value? {
        switch self {
        case .known(let value): return value
        case .unknown(let seen): return seen
        case .fresh: return nil
        }
    }

    /// The same base over a part of the value (one table of a store that
    /// keeps two).
    func map<Part>(_ part: (Value) -> Part) -> RowBase<Part> {
        switch self {
        case .known(let value): return .known(part(value))
        case .fresh: return .fresh
        case .unknown(let seen): return .unknown(seen: seen.map(part))
        }
    }

}

/// Whether emptying the stock is what a write means to do. Every write of a
/// row store says so; an empty snapshot under `refused` that would remove
/// rows is refused and logged instead of written.
nonisolated enum RowEmptying: Equatable, Sendable {
    /// Emptying is the action of the write (the last one deleted, the
    /// queue sent).
    case allowed
    /// The write adds or changes; an empty snapshot here is a fault.
    case refused
}

extension RowBase {
    /// The rows a write of `current` diffs against, for rows keyed by id:
    /// the known rows, or without a known base the rows the start read that
    /// are gone from `current`, so they are removed and nothing else is.
    nonisolated func previous<Row>(for current: [String: Row]) -> [String: Row] where Value == [String: Row] {
        switch self {
        case .known(let rows): return rows
        case .unknown(let seen?): return seen.filter { current[$0.key] == nil }
        case .fresh, .unknown(seen: nil): return [:]
        }
    }

    /// Whether a write of `current` is refused: an empty snapshot that is
    /// not meant to empty and would remove rows (`removable`).
    nonisolated func refuses<Row>(_ current: [String: Row], _ emptying: RowEmptying) -> Bool
    where Value == [String: Row] {
        current.isEmpty && emptying == .refused && !(removable?.isEmpty ?? true)
    }

    /// The same rule for an ordered stock whose rows carry their id (the
    /// podcast subscriptions keep their order): the known rows, or the rows
    /// the start read whose id is gone from `current`.
    nonisolated func previous<Row: Identifiable>(for current: [Row]) -> [Row]
    where Value == [Row], Row.ID == String {
        switch self {
        case .known(let rows): return rows
        case .unknown(let seen?):
            let ids = Set(current.map(\.id))
            return seen.filter { !ids.contains($0.id) }
        case .fresh, .unknown(seen: nil): return []
        }
    }

    /// The same refusal for an ordered stock.
    nonisolated func refuses<Row>(_ current: [Row], _ emptying: RowEmptying) -> Bool where Value == [Row] {
        current.isEmpty && emptying == .refused && !(removable?.isEmpty ?? true)
    }
}
