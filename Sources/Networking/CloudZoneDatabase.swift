// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CloudKit
import Foundation

/// What a record type says to live in a zone of its own: how a value is
/// named, how it goes into a record and how it comes back. The mechanics
/// of a zone (account, zone, silent push, changes by token, a batched
/// modify, the failure translation) are written once in `CKZoneDatabase`
/// and never per type; a second zone is a second codec, not a second
/// database class.
protocol CloudRecordCodec: Sendable {
    associatedtype Value: Equatable & Sendable
    static var zoneName: String { get }
    static var recordType: String { get }
    /// One fixed id per device, so the subscription is written once and
    /// re-saving it changes nothing.
    static var subscriptionID: String { get }
    static func recordName(for value: Value) -> String
    static func fill(_ record: CKRecord, with value: Value)
    /// Nil when the record lacks what a value needs.
    static func value(from record: CKRecord) -> Value?
}

/// What one fetch since a token brought.
nonisolated struct CloudZoneChanges<Value: Equatable & Sendable>: Equatable, Sendable {
    var changed: [Value] = []
    /// Records deleted on the server, by record name (not a tombstone: a
    /// deletion of the row itself).
    var deletedRecordNames: [String] = []
    /// The token to ask with next time, opaque.
    var token: Data?
    var moreComing = false
}

/// The questions a carrier asks its zone. Small on purpose: a witness
/// answers them from a dictionary.
protocol CloudZoneDatabase<Value>: AnyObject, Sendable {
    associatedtype Value: Equatable & Sendable
    func accountAvailable() async -> Bool
    func ensureZone() async throws
    /// Asks the cloud to push silently when the zone changes. Once per
    /// device; a push only WAKES the fetch, it never carries a value.
    func ensureSubscription() async throws
    func changes(since token: Data?) async throws -> CloudZoneChanges<Value>
    /// Saves and deletes; the caller batches to at most `CloudZoneLimits.batch`.
    func modify(save: [Value], delete recordNames: [String]) async throws
}

nonisolated enum CloudZoneLimits {
    /// CloudKit refuses more than 400 records in one modify.
    static let batch = 400
}

/// The real thing: the private database of the app's container, one
/// zone and one record type per codec. Every call is one CloudKit
/// operation; errors come back as `CloudStandFailure`.
final class CKZoneDatabase<Codec: CloudRecordCodec>: CloudZoneDatabase {
    typealias Value = Codec.Value

    static var containerID: String { "iCloud.fm.maer.app" }

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: Codec.zoneName, ownerName: CKCurrentUserDefaultName)

    init(container: CKContainer = CKContainer(identifier: "iCloud.fm.maer.app")) {
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
            throw CloudZoneFailures.failure(from: error)
        }
    }

    /// The zone's silent push. `shouldSendContentAvailable` is what makes
    /// it silent: no alert, no badge, no sound. The subscription id is
    /// fixed, so saving it again is idempotent.
    func ensureSubscription() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Codec.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
        } catch {
            throw CloudZoneFailures.failure(from: error)
        }
    }

    func changes(since token: Data?) async throws -> CloudZoneChanges<Value> {
        let previous = token.flatMap { data in
            // tragbar, weil ein unlesbares Token wie keines zaehlt: der Abzug beginnt von vorn
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous)
            var out = CloudZoneChanges<Value>()
            for (_, modification) in result.modificationResultsByID {
                guard case .success(let change) = modification,
                      let value = Codec.value(from: change.record) else { continue }
                out.changed.append(value)
            }
            out.deletedRecordNames = result.deletions.map(\.recordID.recordName)
            out.token = try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            out.moreComing = result.moreComing
            return out
        } catch {
            throw CloudZoneFailures.failure(from: error)
        }
    }

    func modify(save: [Value], delete recordNames: [String]) async throws {
        let records = save.map { value -> CKRecord in
            let record = CKRecord(recordType: Codec.recordType,
                                  recordID: CKRecord.ID(recordName: Codec.recordName(for: value), zoneID: zoneID))
            Codec.fill(record, with: value)
            return record
        }
        let deletions = recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            // allKeys: the newest wins by the moment in the record, the
            // server's change tag has nothing to say about it.
            let outcome = try await database.modifyRecords(saving: records, deleting: deletions,
                                                           savePolicy: .allKeys, atomically: false)
            // The call answers per record; a record the server refused
            // (a type missing from the production schema, a quota) is a
            // failure of the batch, so the queue keeps it. A record the
            // server took is saved again next round with allKeys, which
            // is the same record.
            if let refused = CloudZoneFailures.firstRefusal(outcome.saveResults.values.map { $0.map { _ in () } })
                ?? CloudZoneFailures.firstRefusal(outcome.deleteResults.values.map { $0 }) {
                throw CloudZoneFailures.failure(from: refused)
            }
        } catch {
            throw CloudZoneFailures.failure(from: error)
        }
    }
}

/// The one translation of CloudKit's errors into the three the carriers
/// act on.
nonisolated enum CloudZoneFailures {
    static func firstRefusal(_ results: [Result<Void, any Error>]) -> (any Error)? {
        for result in results {
            if case .failure(let error) = result { return error }
        }
        return nil
    }

    static func failure(from error: Error) -> CloudStandFailure {
        if let failure = error as? CloudStandFailure { return failure }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .accountTemporarilyUnavailable: return .noAccount
            case .changeTokenExpired: return .tokenExpired
            case .partialFailure:
                // The batch as a whole failed on some records: the first
                // record's own error names the reason.
                if let inner = ck.partialErrorsByItemID?.values.first { return failure(from: inner) }
                return .transport("ck \(ck.code.rawValue)")
            default:
                // The server's own sentence, when it sends one ("Cannot
                // create new type Stand in production schema"); it never
                // carries a value, the record names are ids or hashes.
                let server = (ck.errorUserInfo["ServerErrorDescription"] as? String).map { " \($0)" } ?? ""
                return .transport("ck \(ck.code.rawValue)\(server)")
            }
        }
        return .transport(String(describing: type(of: error)))
    }
}
