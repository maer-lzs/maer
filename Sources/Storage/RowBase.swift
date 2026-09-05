// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a store knows about its rows before a write, and the one rule that
/// follows from it. The base advances ONLY after a write landed: a failed
/// write leaves it where it was, so the next write diffs against the last
/// state that really is in the rows. A start whose read FAILED (not: found
/// nothing) leaves the rows unknown: the first write then only upserts and
/// removes nothing, so rows the store never saw are not buried under an
/// empty or older stand.
nonisolated enum RowBase<Value> {
    /// The rows as the last landed write or the successful start read left them.
    case known(Value)
    /// The start read succeeded and found no rows: the first write is the
    /// diff against nothing (every row an upsert, the table was empty).
    case fresh
    /// The start read failed: the rows may hold anything.
    case unknown

    /// A whole replace is not a plan: it belongs to the migration paths
    /// alone. Without a known base the write upserts and removes nothing.
    enum Plan: Equatable, Sendable {
        case diff
        case upsertOnly
    }

    var plan: Plan {
        switch self {
        case .known: return .diff
        case .fresh, .unknown: return .upsertOnly
        }
    }

    var knownValue: Value? {
        if case .known(let value) = self { return value }
        return nil
    }

    /// The base after a write: landed, the snapshot is what the rows hold;
    /// failed, nothing changes.
    func landed(_ snapshot: Value, success: Bool) -> RowBase<Value> {
        success ? .known(snapshot) : self
    }
}
