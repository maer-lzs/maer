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
nonisolated struct CloudStandChanges: Equatable, Sendable {
    var changed: [CloudStandRecord] = []
    /// Items whose record was deleted on the server (not a tombstone: a
    /// deletion of the row itself).
    var deletedItemIds: [String] = []
    /// The token to ask with next time, opaque.
    var token: Data?
    var moreComing = false
}

/// Why the cloud could not answer. `noAccount` means the fallback runs
/// for the session; `tokenExpired` means ask again from the start;
/// `transport` means try again on the next tick.
nonisolated enum CloudStandFailure: Error, Equatable, Sendable {
    case noAccount
    case tokenExpired
    case transport(String)
}

/// The three questions the carrier asks the cloud. Small on purpose: a
/// witness answers them from a dictionary.
protocol CloudStandDatabase: AnyObject, Sendable {
    func accountAvailable() async -> Bool
    func ensureZone() async throws
    func changes(since token: Data?) async throws -> CloudStandChanges
    /// Saves and deletes; the caller batches to at most `CloudStandLimits.batch`.
    func modify(save: [CloudStandRecord], delete itemIds: [String]) async throws
}

nonisolated enum CloudStandLimits {
    /// CloudKit refuses more than 400 records in one modify.
    static let batch = 400
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

/// The real thing: the private database of the app's container, one
/// zone `stand`, one record type `Stand`. Every call is one CloudKit
/// operation; errors come back as `CloudStandFailure`.
final class CKStandDatabase: CloudStandDatabase {
    static let containerID = "iCloud.fm.maer.app"
    static let zoneName = "stand"
    static let recordType = "Stand"

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CKStandDatabase.zoneName, ownerName: CKCurrentUserDefaultName)

    init(container: CKContainer = CKContainer(identifier: CKStandDatabase.containerID)) {
        self.container = container
    }

    func accountAvailable() async -> Bool {
        // tragbar, weil ein Fehler der Kontofrage wie "kein Konto" zaehlt: der Rueckfall laeuft
        ((try? await container.accountStatus()) ?? .couldNotDetermine) == .available
    }

    func ensureZone() async throws {
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        } catch {
            throw Self.failure(from: error)
        }
    }

    func changes(since token: Data?) async throws -> CloudStandChanges {
        let previous = token.flatMap { data in
            // tragbar, weil ein unlesbares Token wie keines zaehlt: der Abzug beginnt von vorn
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous)
            var out = CloudStandChanges()
            for (_, modification) in result.modificationResultsByID {
                guard case .success(let change) = modification,
                      let record = Self.stand(from: change.record) else { continue }
                out.changed.append(record)
            }
            out.deletedItemIds = result.deletions.map(\.recordID.recordName)
            out.token = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            out.moreComing = result.moreComing
            return out
        } catch {
            throw Self.failure(from: error)
        }
    }

    func modify(save: [CloudStandRecord], delete itemIds: [String]) async throws {
        let records = save.map { stand -> CKRecord in
            let record = CKRecord(recordType: Self.recordType,
                                  recordID: CKRecord.ID(recordName: CloudStandNaming.recordName(for: stand.itemId), zoneID: zoneID))
            record["item"] = stand.itemId as CKRecordValue
            record["position"] = stand.entry[0] as CKRecordValue
            record["t"] = stand.entry[1] as CKRecordValue
            if stand.entry.count > 2 { record["duration"] = stand.entry[2] as CKRecordValue }
            if stand.entry.count > 3 { record["form"] = stand.entry[3] as CKRecordValue }
            record["tombstone"] = (stand.tombstone ? 1 : 0) as CKRecordValue
            return record
        }
        let deletions = itemIds.map { CKRecord.ID(recordName: CloudStandNaming.recordName(for: $0), zoneID: zoneID) }
        do {
            // allKeys: the newest wins by the moment in the record, the
            // server's change tag has nothing to say about it.
            _ = try await database.modifyRecords(saving: records, deleting: deletions,
                                                 savePolicy: .allKeys, atomically: false)
        } catch {
            throw Self.failure(from: error)
        }
    }

    /// The defaults entry out of a record; nil when the record lacks
    /// item, position or moment.
    nonisolated static func stand(from record: CKRecord) -> CloudStandRecord? {
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

    nonisolated static func failure(from error: Error) -> CloudStandFailure {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .accountTemporarilyUnavailable: return .noAccount
            case .changeTokenExpired: return .tokenExpired
            default: return .transport("ck \(ck.code.rawValue)")
            }
        }
        return .transport(String(describing: type(of: error)))
    }
}
