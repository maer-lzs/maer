// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Audiobooks downloaded while you listen: what to download, what goes.
nonisolated enum AudiobookPreload {
    /// A book as the rule sees it.
    struct Book: Equatable, Sendable {
        let id: String
        let bytes: Int64
        let lastHeardMs: Double
        var finishedAtMs: Double? = nil
    }

    struct Plan: Equatable, Sendable {
        var download: [String] = []
        var remove: [String] = []
    }

    /// The space the automatic books may take, to choose from.
    static let budgetsGB: [Int] = [2, 5, 10]
    static let defaultBudgetGB = 5
    /// What stays free on the device: nothing downloads into it.
    static let reserveBytes: Int64 = 2_000_000_000
    /// A finished automatic book stays this long.
    static let keepAfterFinishMs: Double = 86_400_000

    static func budgetBytes(gb: Int) -> Int64 { Int64(gb) * 1_000_000_000 }

    /// Only with the switch on and only on Wi-Fi.
    static func mayLoad(enabled: Bool, onWiFi: Bool) -> Bool { enabled && onWiFi }

    /// The books to have: the one started now, then those of Continue
    /// Listening in their order, then the next of a finished series; each
    /// once.
    static func candidates(started: String?, continueRow: [String], nextInSeries: String?) -> [String] {
        var out: [String] = []
        for id in [started].compactMap({ $0 }) + continueRow + [nextInSeries].compactMap({ $0 }) where !out.contains(id) {
            out.append(id)
        }
        return out
    }

    /// What to download and what goes. `held` are this device's automatic
    /// downloads only. A finished one goes a day after its end. A wanted
    /// book downloads when it fits the space; when the space is full, the
    /// automatic books heard longest ago go for it, never one heard later
    /// than it and never one that is wanted. Nothing downloads that would
    /// leave less than `reserveBytes` free on the device.
    static func plan(wanted: [Book], held: [Book], budgetBytes: Int64, freeBytes: Int64, nowMs: Double) -> Plan {
        var plan = Plan()
        let wantedIds = Set(wanted.map(\.id))
        var kept: [Book] = []
        for book in held {
            if let finished = book.finishedAtMs, nowMs - finished >= keepAfterFinishMs {
                plan.remove.append(book.id)
            } else {
                kept.append(book)
            }
        }
        var free = freeBytes + held.filter { plan.remove.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        var used = kept.reduce(0) { $0 + $1.bytes }
        let heldIds = Set(held.map(\.id))
        for book in wanted where !heldIds.contains(book.id) && book.finishedAtMs == nil {
            guard book.bytes <= budgetBytes else { continue }
            // The automatic books that may give way, heard longest ago first.
            let yielding = kept.filter { !wantedIds.contains($0.id) && $0.lastHeardMs < book.lastHeardMs }
                .sorted { $0.lastHeardMs < $1.lastHeardMs }
            var gone: [Book] = []
            var room = budgetBytes - used
            for candidate in yielding where room < book.bytes {
                gone.append(candidate)
                room += candidate.bytes
            }
            let freed = gone.reduce(0) { $0 + $1.bytes }
            guard room >= book.bytes, free + freed - book.bytes >= reserveBytes else { continue }
            plan.remove += gone.map(\.id)
            kept.removeAll { candidate in gone.contains { $0.id == candidate.id } }
            kept.append(book)
            used = used - freed + book.bytes
            free = free + freed - book.bytes
            plan.download.append(book.id)
        }
        return plan
    }
}
