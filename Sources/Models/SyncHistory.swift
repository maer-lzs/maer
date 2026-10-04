// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One persisted sync run. The settings' "Sync History" list renders
/// these. Modeled future-proof: entries carry a stable id and a device id so a
/// later stage can merge histories across devices (iCloud; Android via an
/// alternative store). Deliberately NOT built now.
nonisolated struct SyncHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Service: String, Codable, Sendable {
        case gpodder
        case absProgress
        case iCloud
        /// The music library refresh is a visible sync operation too.
        case music
        /// The pot on the Mär sync service, when the person set one up.
        /// A rollback to an older build on the same device reads this
        /// history and cannot decode this case; the ring is one row per
        /// entry, so that build skips the entry and keeps the rest.
        case maerSync
        /// This device's listening statistics, when their rows cannot be
        /// read and a write is held: local, no service. An older build
        /// skips the entry like `maerSync`.
        case statistics
    }

    enum Direction: String, Codable {
        case up, down, both
    }

    /// Result counters in DISPLAY ORDER ("2 subscriptions up, 1,299 positions
    /// up"). An ordered array, not a dictionary, so the line is stable.
    struct Counter: Codable, Equatable, Sendable {
        enum Key: String, Codable {
            case subscriptionsUp, subscriptionsDown, positionsUp, positionsDown
            case albumsUpdated, songsUpdated
            /// Subscriptions REMOVED by a sync (possible data-loss trail): local
            /// unsubscribe vs. dropped from the server. Small "plausible" removes
            /// used to be applied silently. Now they always land in the history.
            case subscriptionsRemovedLocally, subscriptionsRemovedFromServer
            /// Feeds that arrived over iCloud but need a sign-in on this
            /// device before they can be followed.
            case subscriptionsNeedingSignIn
            /// Feeds that arrived over iCloud and failed here for another
            /// reason (gone, timeout, unreachable, unreadable).
            case subscriptionsNotFollowed
        }
        let key: Key
        let value: Int
    }

    let id: UUID
    let deviceId: String
    let startedAt: Date
    let duration: TimeInterval
    let service: Service
    let direction: Direction
    let counters: [Counter]
    /// Error in clear text. Nil for a clean run.
    let error: String?
    /// A tripped guard (mass-delete veto) becomes a PERMANENT marked
    /// entry instead of a transient warning.
    let guardNote: String?
    /// The exact feeds a sync removed (local unsubscribe or server drop), as
    /// human-readable "title — url" lines, so a suspected subscription loss can
    /// be inspected after the fact. Optional: old entries decode as nil.
    let removedFeeds: [String]?
}

/// Pure, testable entry creation + the ring-buffer trim.
nonisolated enum SyncHistory {
    /// The history keeps the last N runs.
    static let ringLimit = 50

    /// Build an entry; `id`/`startedAt` injectable for tests.
    static func entry(
        service: SyncHistoryEntry.Service,
        direction: SyncHistoryEntry.Direction,
        counters: [SyncHistoryEntry.Counter],
        duration: TimeInterval,
        error: String? = nil,
        guardNote: String? = nil,
        removedFeeds: [String]? = nil,
        deviceId: String,
        id: UUID = UUID(),
        startedAt: Date = Date()
    ) -> SyncHistoryEntry {
        SyncHistoryEntry(
            id: id, deviceId: deviceId, startedAt: startedAt,
            duration: max(0, duration), service: service, direction: direction,
            counters: counters.filter { $0.value != 0 },
            error: error, guardNote: guardNote,
            removedFeeds: (removedFeeds?.isEmpty ?? true) ? nil : removedFeeds)
    }

    /// Ring buffer: newest first, capped at `limit`.
    static func trimmed(_ entries: [SyncHistoryEntry], limit: Int = ringLimit) -> [SyncHistoryEntry] {
        Array(entries.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
}
