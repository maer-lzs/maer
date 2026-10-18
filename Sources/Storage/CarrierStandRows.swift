// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The stands a carrier keeps of the other side, in rows: the CloudKit
/// carrier's mirror and queue, and the Mär sync service's per identity.
/// Before, each lived as one blob in the defaults and every send wrote the
/// whole blob again; a row per title writes only what changed.
///
/// One table, one keeper: an owner is the name the blob had in the
/// defaults (`cloudStandMirror`, `maerSyncStands.<scope>`), a row is
/// `<owner>␟<title>`. A keeper per owner would read the other owners' rows
/// as removed. The memory holds every owner, so the rows of an identity
/// that is not signed in stay where they are.
///
/// The way back: a build before this one reads the blobs and the change
/// token or version beside them. The move takes the blobs AND the token and
/// version, and this build keeps its own under new names, so an older build
/// finds neither and fetches from the start instead of taking a stock for
/// known that it does not hold. `cloudStandMigrated` stays: without it an
/// older build would send the key-value blob over the cloud's records.
@MainActor
final class CarrierStandRows {
    static let shared = CarrierStandRows(database: .shared, defaults: AppStorageKeys.store)

    /// The blobs before the rows, by owner family: the mirror and queue of
    /// each carrier, the service's with or without an identity scope.
    nonisolated static let legacyOwners = ["cloudStandMirror", "cloudStandQueue"]
    nonisolated static let legacyScopedOwners = ["maerSyncStands", "maerSyncStandsQueue"]
    /// What the older builds read beside the blobs and must not find again.
    nonisolated static let legacyToken = "cloudStandToken"
    nonisolated static let legacyScopedVersion = "maerSyncStandsVersion"
    nonisolated static let moveStartedKey = "carrierStandsMoveStarted"
    nonisolated static let movedKey = "carrierStandsMoved"
    nonisolated static let separator: Character = "\u{1F}"

    private let keeper: RowKeeper<[Double]>
    private let defaults: UserDefaults
    /// Owner to title to entry; nil until the rows were read.
    private var held: [String: [String: [Double]]]?
    /// The same as rows, kept beside it and changed entry by entry, so a
    /// write hands the keeper its snapshot without building every key on
    /// the main thread again.
    private var flat: [String: [Double]] = [:]

    init(database: MaerDatabase, defaults: UserDefaults) {
        self.defaults = defaults
        keeper = RowKeeper(database: database, table: .carrierStand, label: "CARRIERSTAND")
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
    /// yet: an owner's stands are then unknown, not empty. A carrier drops
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

    /// The rows of the app's defaults, or for a witness's own defaults a
    /// database file of their own, named in that domain, so a second
    /// session on the same domain finds the rows the first one wrote.
    static func matching(_ defaults: UserDefaults) -> CarrierStandRows {
        if defaults === AppStorageKeys.store { return shared }
        let key = "carrierStandRowsFile"
        let path = defaults.string(forKey: key) ?? {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("carrier-stand-\(UUID().uuidString).sqlite").path
            defaults.set(path, forKey: key)
            return path
        }()
        if let known = witnesses[path] { return known }
        let rows = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        witnesses[path] = rows
        return rows
    }
    private static var witnesses: [String: CarrierStandRows] = [:]

    /// What an owner holds.
    func rows(_ owner: String) -> [String: [Double]] {
        startIfNeeded()
        return held?[owner] ?? [:]
    }

    /// An owner's stands as they are now; the rows get what changed.
    func set(_ owner: String, _ rows: [String: [Double]]) {
        startIfNeeded()
        guard place(owner, rows) else { return }
        if rows.isEmpty {
            // Emptying is the action: the owner's last stand went (the
            // queue was sent, the other side holds nothing).
            keeper.write(emptying: .allowed, snapshot)
        } else {
            write()
        }
    }

    /// The same stands under another owner's name (the service's identity
    /// carried to a new key, or the plain keys taken over by the first one).
    func rename(owner from: String, to next: String) {
        startIfNeeded()
        guard let moving = held?[from] else { return }
        _ = place(from, [:])
        _ = place(next, moving)
        write()
    }

    /// An owner's stands into the memory, the rows changed only where an
    /// entry changed; false when nothing did.
    private func place(_ owner: String, _ rows: [String: [Double]]) -> Bool {
        let before = held?[owner] ?? [:]
        var changed = false
        for (title, entry) in rows where before[title] != entry {
            flat[Self.key(owner, title)] = entry
            changed = true
        }
        for title in before.keys where rows[title] == nil {
            flat[Self.key(owner, title)] = nil
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
    private var snapshot: @MainActor () -> [String: [Double]]? {
        { [weak self] in self?.flat }
    }

    // MARK: - Start and move

    private func startIfNeeded() {
        guard held == nil else { return }
        flat = keeper.startNow() ?? [:]
        held = Self.owners(of: flat)
        // Over rows nobody read, the blobs would win the merge: the move
        // waits for a start that reads.
        guard !defaults.bool(forKey: Self.movedKey), !keeper.startReadFailed else { return }
        move()
    }

    /// The blobs into the rows, once. The mark goes first; the blobs, the
    /// token and the versions go only after the rows landed. A move broken
    /// off finds the blobs again and merges, the rows winning: they are the
    /// newer word.
    private func move() {
        defaults.set(true, forKey: Self.moveStartedKey)
        let found = Self.legacyBlobs(in: defaults)
        guard !found.isEmpty else {
            finishMove(owners: [])
            return
        }
        for (owner, stands) in found {
            _ = place(owner, stands.merging(held?[owner] ?? [:]) { _, rows in rows })
        }
        keeper.mark = { [weak self] in
            (statements: [], landed: { self?.finishMove(owners: Array(found.keys)) })
        }
        write()
        Logger.library.notice("CARRIERSTAND move owners=\(found.count) stands=\(found.values.map(\.count).reduce(0, +))")
    }

    private func finishMove(owners: [String]) {
        keeper.mark = nil
        for owner in owners { defaults.removeObject(forKey: owner) }
        defaults.removeObject(forKey: Self.legacyToken)
        for key in defaults.dictionaryRepresentation().keys
        where key == Self.legacyScopedVersion || key.hasPrefix(Self.legacyScopedVersion + ".") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: Self.movedKey)
        Logger.library.notice("CARRIERSTAND moved owners=\(owners.count); the blobs, the token and the versions are gone")
    }

    /// Every blob of the families above in the defaults, by its key.
    nonisolated static func legacyBlobs(in defaults: UserDefaults) -> [String: [String: [Double]]] {
        var out: [String: [String: [Double]]] = [:]
        for key in defaults.dictionaryRepresentation().keys where isLegacyOwner(key) {
            guard let data = defaults.data(forKey: key) else { continue }
            // bearable, because an unreadable blob only costs a full pull; the truth lies on the other side and on the device
            out[key] = (try? JSONDecoder().decode([String: [Double]].self, from: data)) ?? [:]
        }
        return out
    }

    nonisolated static func isLegacyOwner(_ key: String) -> Bool {
        legacyOwners.contains(key)
            || legacyScopedOwners.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    // MARK: - Rows (pure)

    nonisolated static func key(_ owner: String, _ title: String) -> String {
        owner + String(separator) + title
    }

    nonisolated static func owners(of rows: [String: [Double]]) -> [String: [String: [Double]]] {
        var out: [String: [String: [Double]]] = [:]
        for (key, entry) in rows {
            guard let cut = key.firstIndex(of: separator) else { continue }
            out[String(key[..<cut]), default: [:]][String(key[key.index(after: cut)...])] = entry
        }
        return out
    }
}
