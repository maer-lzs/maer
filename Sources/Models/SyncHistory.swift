import Foundation

/// F9: one persisted sync run — the settings' "Sync History" list renders
/// these. Modeled future-proof: entries carry a stable id and a device id so a
/// later stage can merge histories across devices (iCloud; Android via an
/// alternative store) — deliberately NOT built now.
nonisolated struct SyncHistoryEntry: Codable, Identifiable, Equatable {
    enum Service: String, Codable {
        case gpodder
        case absProgress
        case iCloud
    }

    enum Direction: String, Codable {
        case up, down, both
    }

    /// Result counters in DISPLAY ORDER ("2 subscriptions up, 1,299 positions
    /// up") — an ordered array, not a dictionary, so the line is stable.
    struct Counter: Codable, Equatable {
        enum Key: String, Codable {
            case subscriptionsUp, subscriptionsDown, positionsUp, positionsDown
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
    /// Error in clear text — nil for a clean run.
    let error: String?
    /// F9/S20: a tripped guard (mass-delete veto) becomes a PERMANENT marked
    /// entry instead of a transient warning.
    let guardNote: String?
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
        deviceId: String,
        id: UUID = UUID(),
        startedAt: Date = Date()
    ) -> SyncHistoryEntry {
        SyncHistoryEntry(
            id: id, deviceId: deviceId, startedAt: startedAt,
            duration: max(0, duration), service: service, direction: direction,
            counters: counters.filter { $0.value != 0 },
            error: error, guardNote: guardNote)
    }

    /// Ring buffer: newest first, capped at `limit`.
    static func trimmed(_ entries: [SyncHistoryEntry], limit: Int = ringLimit) -> [SyncHistoryEntry] {
        Array(entries.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }
}
