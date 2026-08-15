// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 🟡 P10: archive.org's SEARCH INDEX and its actual holdings drift apart —
/// withdrawn items stay in the index as ghost records and land in Discover
/// with a dead cover and a dead stream (the owner's screenshot: two
/// georgeblood 78s whose `metadata` endpoint answers `{"error": …}` while a
/// healthy neighbour returns 20 files in the same moment).
///
/// **The three-way ladder, exactly as for the 401 probe** — because this is
/// the same class ("a throw is not an end"):
/// * **service unreachable** → remember NOTHING. A network failure says
///   nothing about the item.
/// * **service reachable, item answers error/404** → remember the IDENTIFIER
///   as dead, WITH an expiry: archive.org does bring items back, and a
///   permanent verdict from one measurement would be exactly the poisoned
///   negative cache of `95c5c16`.
/// * **healthy** → remember nothing (and drop an earlier mark).
///
/// Only the identifier is remembered, never a judgement about content.
/// Curated surfaces (Discover, recommendations) skip what is marked; SEARCH
/// and direct navigation never do — same line as "not interested".
nonisolated enum DeadCatalogItems {
    /// archive.org restores items now and then, so a mark is a measurement
    /// with a shelf life, not a verdict.
    static let ttlDays: Double = 30
    private static let storeKey = "deadCatalogItems"

    /// What a liveness check found.
    enum Liveness: Equatable {
        case alive
        case dead
        /// The service did not answer — says nothing about the item.
        case unknown
    }

    // MARK: - Store (identifier → marked-at timestamp)

    static func marked(defaults: UserDefaults = .standard) -> [String: Double] {
        (defaults.dictionary(forKey: storeKey) as? [String: Double]) ?? [:]
    }

    static func isDead(_ identifier: String, now: Date = Date(),
                       defaults: UserDefaults = .standard) -> Bool {
        guard let markedAt = marked(defaults: defaults)[identifier] else { return false }
        return now.timeIntervalSince1970 - markedAt < ttlDays * 86_400
    }

    /// Apply a liveness result. `unknown` writes NOTHING — that is the whole
    /// point of the ladder.
    static func note(_ liveness: Liveness, for identifier: String,
                     now: Date = Date(), defaults: UserDefaults = .standard) {
        var store = marked(defaults: defaults)
        switch liveness {
        case .unknown:
            return
        case .dead:
            guard store[identifier] == nil else { return }
            store[identifier] = now.timeIntervalSince1970
            Logger.library.notice("CATALOG item marked DEAD (ttl \(Int(ttlDays))d): \(identifier, privacy: .public)")
        case .alive:
            guard store.removeValue(forKey: identifier) != nil else { return }
            Logger.library.notice("CATALOG item alive again: \(identifier, privacy: .public)")
        }
        // Expired marks leave on every write — the list stays small and a
        // returned item is not blocked by an old measurement.
        let cutoff = now.timeIntervalSince1970 - ttlDays * 86_400
        store = store.filter { $0.value >= cutoff }
        defaults.set(store, forKey: storeKey)
    }

    /// Pure classification of a metadata answer — the ladder without I/O, so
    /// the distinction that matters is testable.
    static func liveness(httpStatus: Int?, body: Data?) -> Liveness {
        guard let httpStatus else { return .unknown }          // transport failure
        if httpStatus == 404 { return .dead }
        guard (200...299).contains(httpStatus) else { return .unknown }  // 5xx = service
        guard let body else { return .unknown }
        // archive.org answers a withdrawn item with HTTP 200 and an error
        // object — the measured shape from the order.
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .unknown
        }
        if json["error"] != nil { return .dead }
        // A healthy item carries files; an empty envelope is not a verdict.
        if let files = json["files"] as? [Any], !files.isEmpty { return .alive }
        if json["metadata"] != nil { return .alive }
        return .unknown
    }
}
