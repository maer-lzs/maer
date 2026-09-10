// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CloudKit
import CryptoKit
import Foundation
import OSLog

/// One listening stand as CloudKit carries it: the item, the defaults
/// entry (`[position, updatedAtMs, duration?, form?]`) and whether it is a
/// tombstone (a deliberate "unplayed", kept as a record so the moment
/// travels and the newest wins, like the zero entry in the pot today).
nonisolated struct CloudStandRecord: Equatable, Sendable {
    var itemId: String
    var entry: [Double]
    var tombstone: Bool
}

/// What one fetch since a token brought.
typealias CloudStandChanges = CloudZoneChanges<CloudStandRecord>

/// Why the cloud could not answer. `noAccount` means the fallback runs
/// for the session; `tokenExpired` means ask again from the start;
/// `transport` means try again on the next tick. Shared by every zone.
nonisolated enum CloudStandFailure: Error, Equatable, Sendable {
    case noAccount
    case tokenExpired
    case transport(String)
}

/// The questions the stand carrier asks its zone: the zone database over
/// the stand codec. A witness answers them from a dictionary.
typealias CloudStandDatabase = CloudZoneDatabase<CloudStandRecord>

nonisolated enum CloudStandLimits {
    /// CloudKit refuses more than 400 records in one modify.
    static let batch = CloudZoneLimits.batch
}

/// The record name of an item: a hash, because record names are capped
/// at 255 characters and an rss id carries a whole guid. The item id
/// itself rides in the `item` field; a deletion is mapped back through
/// the names of what the mirror holds.
nonisolated enum CloudStandNaming {
    static func recordName(for itemId: String) -> String {
        let digest = SHA256.hash(data: Data(itemId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The stand zone: `stand`, one record type `Stand`, fields `item`
/// `position` `t` `duration` `form` `tombstone`, record name = SHA-256 of
/// the item id. The mechanics live in `CKZoneDatabase`.
nonisolated enum CloudStandCodec: CloudRecordCodec {
    typealias Value = CloudStandRecord
    static let zoneName = "stand"
    static let recordType = "Stand"
    static let subscriptionID = "stand-zone"

    static func recordName(for value: CloudStandRecord) -> String {
        CloudStandNaming.recordName(for: value.itemId)
    }

    static func fill(_ record: CKRecord, with stand: CloudStandRecord) {
        record["item"] = stand.itemId as CKRecordValue
        record["position"] = stand.entry[0] as CKRecordValue
        record["t"] = stand.entry[1] as CKRecordValue
        if stand.entry.count > 2 { record["duration"] = stand.entry[2] as CKRecordValue }
        if stand.entry.count > 3 { record["form"] = stand.entry[3] as CKRecordValue }
        record["tombstone"] = (stand.tombstone ? 1 : 0) as CKRecordValue
    }

    /// The defaults entry out of a record; nil when the record lacks
    /// item, position or moment.
    static func value(from record: CKRecord) -> CloudStandRecord? {
        guard let itemId = record["item"] as? String,
              let position = record["position"] as? Double,
              let t = record["t"] as? Double else { return nil }
        var entry = [position, t]
        let duration = record["duration"] as? Double
        let form = record["form"] as? Double
        if let form { entry += [duration ?? 0, form] } else if let duration { entry.append(duration) }
        let tombstone = (record["tombstone"] as? Int64 ?? 0) != 0
        return CloudStandRecord(itemId: itemId, entry: entry, tombstone: tombstone)
    }
}

/// The real thing for the stands: the zone database over the stand codec.
typealias CKStandDatabase = CKZoneDatabase<CloudStandCodec>
