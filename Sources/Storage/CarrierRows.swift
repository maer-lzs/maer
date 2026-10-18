// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What a carrier keeps of the other side, in rows: the stands of the
/// CloudKit carrier and of the Mär sync service per identity
/// (`CarrierStandRows`), and the records of the CloudKit carriers of the
/// choices, the playlists and the statistics (`CarrierRecordRows`). Before,
/// each mirror and queue lived as one blob in the defaults and every send
/// wrote the whole blob again; a row per entry writes only what changed.
///
/// One table per kind of value, one keeper per table: an owner is the name
/// the blob had in the defaults (`cloudStandMirror`, `maerSyncStands.<scope>`,
/// `cloudChoiceQueue`), a row is `<owner>␟<entry>`. A keeper per owner would
/// read the other owners' rows as removed. The memory holds every owner, so
/// the rows of an identity that is not signed in stay where they are.
///
/// The way back: a build before this one reads the blobs and the change
/// token or version beside them. The move takes the blobs AND the tokens and
/// versions, and this build keeps its own under new names, so an older build
/// finds neither and fetches from the start instead of taking a stock for
/// known that it does not hold. The migration marks (`cloudStandMigrated`
/// and its siblings) stay: without them an older build would send the
/// key-value blob over the cloud's records.
@MainActor
final class CarrierRows<Value: Codable & Equatable & Sendable> {
    nonisolated static var separator: Character { "\u{1F}" }

    let spec: CarrierRowsSpec
    private let keeper: RowKeeper<Value>
    private let defaults: UserDefaults
    /// Owner to entry to value; nil until the rows were read.
    private var held: [String: [String: Value]]?
    /// The same as rows, kept beside it and changed entry by entry, so a
    /// write hands the keeper its snapshot without building every key on
    /// the main thread again.
    private var flat: [String: Value] = [:]

    init(spec: CarrierRowsSpec, database: MaerDatabase, defaults: UserDefaults) {
        self.spec = spec
        self.defaults = defaults
        // The spec names one of the tables of the store; a name it does not
        // know is a fault of the source, not of data.
        guard let table = KeyedRowStore<Value>.Table(rawValue: spec.table) else {
            preconditionFailure("CarrierRowsSpec names no table: \(spec.table)")
        }
        keeper = RowKeeper(database: database, table: table, label: spec.label)
        keeper.adopt = { [weak self] read in
            guard let self else { return }
            self.flat = RowKeeper.union(read: read, run: self.flat)
            self.held = Self.owners(of: self.flat)
            let waiting = self.onRead
            self.onRead = []
            for body in waiting { body() }
        }
    }

    /// Whether the rows could not be read at the start and are not read
    /// yet: an owner's entries are then unknown, not empty. A carrier drops
    /// its token or version, so its next round fetches from the start, and
    /// takes the rows into its memory once they are read (`whenRead`);
    /// otherwise its next write would give every read row as removed.
    var unread: Bool {
        startIfNeeded()
        return keeper.startReadFailed
    }

    /// Runs once the rows that could not be read at the start are read.
    func whenRead(_ body: @escaping @MainActor () -> Void) {
        guard unread else { return }
        onRead.append(body)
    }
    private var onRead: [@MainActor () -> Void] = []

    /// What an owner holds.
    func rows(_ owner: String) -> [String: Value] {
        startIfNeeded()
        return held?[owner] ?? [:]
    }

    /// An owner's entries as they are now; the rows get what changed.
    func set(_ owner: String, _ rows: [String: Value]) {
        startIfNeeded()
        guard place(owner, rows) else { return }
        if rows.isEmpty {
            // Emptying is the action: the owner's last entry went (the
            // queue was sent, the other side holds nothing).
            keeper.write(emptying: .allowed, snapshot)
        } else {
            write()
        }
    }

    /// The same entries under another owner's name (the service's identity
    /// carried to a new key, or the plain keys taken over by the first one).
    func rename(owner from: String, to next: String) {
        startIfNeeded()
        guard let moving = held?[from] else { return }
        _ = place(from, [:])
        _ = place(next, moving)
        write()
    }

    /// An owner's entries into the memory, the rows changed only where an
    /// entry changed; false when nothing did.
    private func place(_ owner: String, _ rows: [String: Value]) -> Bool {
        let before = held?[owner] ?? [:]
        var changed = false
        for (entry, value) in rows where before[entry] != value {
            flat[Self.key(owner, entry)] = value
            changed = true
        }
        for entry in before.keys where rows[entry] == nil {
            flat[Self.key(owner, entry)] = nil
            changed = true
        }
        if changed { held?[owner] = rows.isEmpty ? nil : rows }
        return changed
    }

    /// Whether an owner holds anything (a taken over plain key, a witness).
    func holds(_ owner: String) -> Bool {
        startIfNeeded()
        return held?[owner]?.isEmpty == false
    }

    func awaitPendingWrites() async {
        await keeper.awaitPendingWrites()
    }

    private func write() {
        keeper.write(emptying: .refused, snapshot)
    }

    /// The memory as rows, taken when a write runs.
    private var snapshot: @MainActor () -> [String: Value]? {
        { [weak self] in self?.flat }
    }

    // MARK: - Start and move

    private func startIfNeeded() {
        guard held == nil else { return }
        flat = keeper.startNow() ?? [:]
        held = Self.owners(of: flat)
        // Over rows nobody read, the blobs would win the merge: the move
        // waits for a start that reads.
        guard !defaults.bool(forKey: spec.movedKey), !keeper.startReadFailed else { return }
        move()
    }

    /// The blobs into the rows, once. The mark goes first; the blobs, the
    /// tokens and the versions go only after the rows landed. A move broken
    /// off finds the blobs again and merges, the rows winning: they are the
    /// newer word.
    private func move() {
        defaults.set(true, forKey: spec.moveStartedKey)
        let found = Self.legacyBlobs(in: defaults, spec: spec)
        guard !found.isEmpty else {
            finishMove(owners: [])
            return
        }
        for (owner, entries) in found {
            _ = place(owner, entries.merging(held?[owner] ?? [:]) { _, rows in rows })
        }
        keeper.mark = { [weak self] in
            (statements: [], landed: { self?.finishMove(owners: Array(found.keys)) })
        }
        write()
        Logger.library.notice("\(self.spec.label, privacy: .public) move owners=\(found.count) entries=\(found.values.map(\.count).reduce(0, +))")
    }

    private func finishMove(owners: [String]) {
        keeper.mark = nil
        for owner in owners { defaults.removeObject(forKey: owner) }
        for token in spec.legacyTokens { defaults.removeObject(forKey: token) }
        for key in defaults.dictionaryRepresentation().keys where spec.isLegacyVersion(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: spec.movedKey)
        Logger.library.notice("\(self.spec.label, privacy: .public) moved owners=\(owners.count); the blobs, the tokens and the versions are gone")
    }

    /// Every blob of the spec's owners in the defaults, by its key.
    nonisolated static func legacyBlobs(in defaults: UserDefaults, spec: CarrierRowsSpec) -> [String: [String: Value]] {
        var out: [String: [String: Value]] = [:]
        for key in defaults.dictionaryRepresentation().keys where spec.isLegacyOwner(key) {
            guard let data = defaults.data(forKey: key) else { continue }
            // bearable, because an unreadable blob only costs a full pull; the truth lies on the other side and on the device
            out[key] = (try? JSONDecoder().decode([String: Value].self, from: data)) ?? [:]
        }
        return out
    }

    // MARK: - Rows (pure)

    nonisolated static func key(_ owner: String, _ entry: String) -> String {
        owner + String(separator) + entry
    }

    nonisolated static func owners(of rows: [String: Value]) -> [String: [String: Value]] {
        var out: [String: [String: Value]] = [:]
        for (key, value) in rows {
            guard let cut = key.firstIndex(of: separator) else { continue }
            out[String(key[..<cut]), default: [:]][String(key[key.index(after: cut)...])] = value
        }
        return out
    }
}

/// How one kind of carrier rows lives: its table, the blobs it took over,
/// and the tokens and versions an older build must not find again.
nonisolated struct CarrierRowsSpec: Sendable {
    let table: String
    let label: String
    let legacyOwners: [String]
    /// Owners kept per identity as `<owner>.<scope>`, or plain.
    let legacyScopedOwners: [String]
    let legacyTokens: [String]
    /// Versions kept per identity as `<version>.<scope>`, or plain.
    let legacyScopedVersions: [String]
    let moveStartedKey: String
    let movedKey: String

    func isLegacyOwner(_ key: String) -> Bool {
        legacyOwners.contains(key) || legacyScopedOwners.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    func isLegacyVersion(_ key: String) -> Bool {
        legacyScopedVersions.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    static let stands = CarrierRowsSpec(
        table: "carrier_stand", label: "CARRIERSTAND",
        legacyOwners: ["cloudStandMirror", "cloudStandQueue"],
        legacyScopedOwners: ["maerSyncStands", "maerSyncStandsQueue"],
        legacyTokens: ["cloudStandToken"], legacyScopedVersions: ["maerSyncStandsVersion"],
        moveStartedKey: "carrierStandsMoveStarted", movedKey: "carrierStandsMoved")

    static let records = CarrierRowsSpec(
        table: "carrier_record", label: "CARRIERRECORD",
        legacyOwners: ["cloudChoiceMirror", "cloudChoiceQueue", "cloudPlaylistMirror", "cloudPlaylistQueue",
                       "cloudStatsMirror", "cloudStatsQueue"],
        legacyScopedOwners: [],
        legacyTokens: ["cloudChoiceToken", "cloudPlaylistToken", "cloudStatsToken"], legacyScopedVersions: [],
        moveStartedKey: "carrierRecordsMoveStarted", movedKey: "carrierRecordsMoved")
}

/// The stands, `[position, moment, duration?, form?]` per title.
typealias CarrierStandRows = CarrierRows<[Double]>
/// The records of the choices, playlists and statistics, each as the row
/// of text its carrier writes (`rows(of:)`).
typealias CarrierRecordRows = CarrierRows<[String]>

extension CarrierRows where Value == [Double] {
    static var shared: CarrierStandRows { CarrierRowStores.stands }
    static func matching(_ defaults: UserDefaults) -> CarrierStandRows { CarrierRowStores.matching(defaults, spec: .stands) }
    convenience init(database: MaerDatabase, defaults: UserDefaults) {
        self.init(spec: .stands, database: database, defaults: defaults)
    }
    nonisolated static var legacyToken: String { "cloudStandToken" }
    nonisolated static var legacyScopedVersion: String { "maerSyncStandsVersion" }
    nonisolated static var moveStartedKey: String { CarrierRowsSpec.stands.moveStartedKey }
    nonisolated static var movedKey: String { CarrierRowsSpec.stands.movedKey }
    nonisolated static func isLegacyOwner(_ key: String) -> Bool { CarrierRowsSpec.stands.isLegacyOwner(key) }
}

extension CarrierRows where Value == [String] {
    static var shared: CarrierRecordRows { CarrierRowStores.records }
    static func matching(_ defaults: UserDefaults) -> CarrierRecordRows { CarrierRowStores.matching(defaults, spec: .records) }
    convenience init(database: MaerDatabase, defaults: UserDefaults) {
        self.init(spec: .records, database: database, defaults: defaults)
    }
    nonisolated static var movedKey: String { CarrierRowsSpec.records.movedKey }
    nonisolated static func isLegacyOwner(_ key: String) -> Bool { CarrierRowsSpec.records.isLegacyOwner(key) }
}

/// The app's two stores, and for a witness's own defaults a database file
/// of their own, named in that domain, so a second session on the same
/// domain finds the rows the first one wrote.
@MainActor
enum CarrierRowStores {
    static let stands = CarrierStandRows(spec: .stands, database: .shared, defaults: AppStorageKeys.store)
    static let records = CarrierRecordRows(spec: .records, database: .shared, defaults: AppStorageKeys.store)

    static func matching<Value>(_ defaults: UserDefaults, spec: CarrierRowsSpec) -> CarrierRows<Value> {
        if defaults === AppStorageKeys.store {
            // Only the two app stores exist for the app's own defaults.
            let app: AnyObject = spec.table == CarrierRowsSpec.stands.table ? stands : records
            guard let rows = app as? CarrierRows<Value> else {
                preconditionFailure("no app store of \(spec.table) for this value")
            }
            return rows
        }
        let key = "carrierStandRowsFile"
        let path = defaults.string(forKey: key) ?? {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("carrier-stand-\(UUID().uuidString).sqlite").path
            defaults.set(path, forKey: key)
            return path
        }()
        let database = databases[path] ?? MaerDatabase(path: path)
        databases[path] = database
        if let known = witnesses[path + "|" + spec.table] as? CarrierRows<Value> { return known }
        let rows = CarrierRows<Value>(spec: spec, database: database, defaults: defaults)
        witnesses[path + "|" + spec.table] = rows
        return rows
    }
    private static var databases: [String: MaerDatabase] = [:]
    private static var witnesses: [String: AnyObject] = [:]
}
