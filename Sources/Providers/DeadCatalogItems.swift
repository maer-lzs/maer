// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 🟡 archive.org's SEARCH INDEX and its actual holdings drift apart.
/// Withdrawn items stay in the index as ghost records and land in Discover
/// with a dead cover and a dead stream (measured: two georgeblood 78s whose
/// `metadata` endpoint answers `{"error": …}` while a healthy neighbour
/// returns 20 files in the same moment).
///
/// **The three-way ladder, exactly as for the 401 probe**. Because this is
/// the same class ("a throw is not an end"):
/// * **service unreachable** → remember NOTHING. A network failure says
///   nothing about the item.
/// * **service reachable, item answers error/404** → remember the IDENTIFIER
///   as dead, WITH an expiry: archive.org does bring items back, and a
///   permanent verdict from one measurement would be exactly a poisoned
///   negative cache.
/// * **healthy** → remember nothing (and drop an earlier mark).
///
/// Only the identifier is remembered, never a judgement about content.
/// Curated surfaces (Discover, recommendations) skip what is marked; SEARCH
/// and direct navigation never do. Same line as "not interested".
nonisolated enum DeadCatalogItems {
    /// archive.org restores items now and then, so a mark is a measurement
    /// with a shelf life, not a verdict.
    static let ttlDays: Double = 30
    /// The key stands in `DerivedStores`, because it is derived.
    static let storeKey = "deadCatalogItems"

    /// What a liveness check found.
    enum Liveness: Equatable {
        case alive
        case dead
        /// The service did not answer. Says nothing about the item.
        case unknown
    }

    // MARK: - Store (key → marked-at timestamp)

    /// The one key of an entry, whichever form a caller holds: an archive
    /// item by its identifier, raw (the metadata fetch) or as item id
    /// (`lva:X`, a song `lva:X#n`, playback and resolving); any other
    /// catalog's entry by its album id. Before, the fetch wrote the raw
    /// form and playback the item id, and each reader asked one of them:
    /// a mark learned on one side never reached the other.
    static func key(_ id: String) -> String {
        FreeCatalog.archiveIdentifier(of: id) ?? CatalogSongID.album(of: id)
    }

    /// The marks by their one key; a mark an older build stored under the
    /// other form reads the same (the newer moment wins) and is written in
    /// the one form with the next note.
    static func marked(defaults: UserDefaults = .standard) -> [String: Double] {
        let stored = (defaults.dictionary(forKey: storeKey) as? [String: Double]) ?? [:]
        return Dictionary(stored.map { (key($0.key), $0.value) }, uniquingKeysWith: max)
    }

    static func isDead(_ identifier: String, now: Date = Date(),
                       defaults: UserDefaults = .standard) -> Bool {
        guard let markedAt = marked(defaults: defaults)[key(identifier)] else { return false }
        return now.timeIntervalSince1970 - markedAt < ttlDays * 86_400
    }

    /// Apply a liveness result. `unknown` writes NOTHING. That is the whole
    /// point of the ladder.
    static func note(_ liveness: Liveness, for id: String,
                     now: Date = Date(), defaults: UserDefaults = .standard) {
        var store = marked(defaults: defaults)
        let identifier = key(id)
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
        // Expired marks leave on every write. The list stays small and a
        // returned item is not blocked by an old measurement.
        let cutoff = now.timeIntervalSince1970 - ttlDays * 86_400
        store = store.filter { $0.value >= cutoff }
        defaults.set(store, forKey: storeKey)
    }

    /// Pure classification of a metadata answer. The ladder without I/O, so
    /// the distinction that matters is testable.
    static func liveness(httpStatus: Int?, body: Data?) -> Liveness {
        guard let httpStatus else { return .unknown }          // transport failure
        // 404 and 410 alike: the one clean "there is none" of the rule.
        if StatusMeaning.from(status: httpStatus).isAbsence { return .dead }
        guard (200...299).contains(httpStatus) else { return .unknown }  // 5xx = service
        guard let body else { return .unknown }
        // archive.org answers a withdrawn item with HTTP 200 and an error
        // object. The measured shape from the order.
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
