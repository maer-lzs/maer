// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// df0b3bb Punkt 3: "take it off the Continue row WITHOUT losing the position".
///
/// The listening position is never touched — only this row's membership. That
/// is the honest alternative to quietly hiding books, and the function one
/// misses most in such a list.
///
/// The marker stores WHEN a title was hidden (its progress stamp at that
/// moment), not just that it was: if you pick the book up again, newer progress
/// arrives and the entry returns on its own. A plain id set would banish it
/// forever — the user would have to remember an invisible decision.
///
/// Foundation-only (Kern-Schicht bleibt UI-frei), pure and testable.
nonisolated enum ContinueHidden {
    /// Timestamps arrive in seconds or milliseconds (ABS) — same normalisation
    /// as everywhere else in the Continue derivation.
    static func seconds(_ raw: Double) -> Double {
        raw > 4_000_000_000 ? raw / 1000 : raw
    }

    /// Hidden as long as no progress NEWER than the marker has arrived.
    static func isHidden(id: String, lastUpdate: Double, markers: [String: Double]) -> Bool {
        guard let marked = markers[id] else { return false }
        return seconds(lastUpdate) <= marked
    }

    /// Sets the marker to the entry's current progress stamp.
    static func hiding(id: String, lastUpdate: Double, in markers: [String: Double]) -> [String: Double] {
        var next = markers
        next[id] = seconds(lastUpdate)
        return next
    }

    /// Drops markers whose entry has since moved on — keeps the store from
    /// growing without bound as libraries change.
    static func pruned(_ markers: [String: Double], progress: [String: Double]) -> [String: Double] {
        markers.filter { id, marked in
            guard let current = progress[id] else { return true }   // unknown: keep
            return seconds(current) <= marked
        }
    }
}

/// Persistence for the markers (survives restarts, as the order requires).
@MainActor
enum ContinueHiddenStore {
    private static let key = AppStorageKeys.continueHiddenMarkers

    static func markers(defaults: UserDefaults = .standard) -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    static func hide(id: String, lastUpdate: Double, defaults: UserDefaults = .standard) {
        let next = ContinueHidden.hiding(id: id, lastUpdate: lastUpdate, in: markers(defaults: defaults))
        defaults.set(next, forKey: key)
        NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
    }

    static func show(id: String, defaults: UserDefaults = .standard) {
        var next = markers(defaults: defaults)
        next.removeValue(forKey: id)
        defaults.set(next, forKey: key)
        NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
    }

    static func isHidden(id: String, lastUpdate: Double, defaults: UserDefaults = .standard) -> Bool {
        ContinueHidden.isHidden(id: id, lastUpdate: lastUpdate, markers: markers(defaults: defaults))
    }
}

extension Notification.Name {
    /// Posted when a title is hidden from / returned to the Continue rows, so
    /// the surfaces recompute (same mechanism the other stores use).
    static let continueHiddenChanged = Notification.Name("continueHiddenChanged")
}
