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
        commit(emptied: rows.isEmpty)
    }

    /// One entry of an owner; nil when it holds none.
    func entry(_ owner: String, _ entry: String) -> Value? {
        startIfNeeded()
        return held?[owner]?[entry]
    }

    /// One entry of an owner as it is now, nil removes it; the other entries
    /// stay as they are, and nothing else is compared.
    func setEntry(_ owner: String, _ entry: String, _ value: Value?) {
        startIfNeeded()
        var rows = held?.removeValue(forKey: owner) ?? [:]
        let changed = rows[entry] != value
        rows[entry] = value
        held?[owner] = rows.isEmpty ? nil : rows
        guard changed else { return }
        flat[Self.key(owner, entry)] = value
        commit(emptied: rows.isEmpty)
    }

    /// The entries of an owner that `gone` names leave; the rest stay.
    func removeEntries(_ owner: String, where gone: (String) -> Bool) {
        startIfNeeded()
        var rows = held?.removeValue(forKey: owner) ?? [:]
        let leaving = rows.keys.filter(gone)
        for entry in leaving {
            rows[entry] = nil
            flat[Self.key(owner, entry)] = nil
        }
        held?[owner] = rows.isEmpty ? nil : rows
        guard !leaving.isEmpty else { return }
        commit(emptied: rows.isEmpty)
    }

    private func commit(emptied: Bool) {
        if emptied {
            // Emptying is the action: the owner's last entry went (the
            // queue was sent, the other side holds nothing, the last title
            // with an entry left the library).
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

    /// The blobs into the rows, once. The blobs, the tokens and the versions
    /// go, and the mark `movedKey` is set, only after the rows landed. A
    /// move broken off before that finds the blobs again and merges, the
    /// rows winning: they are the newer word. No mark of a begun move is
    /// needed for that, the missing `movedKey` says it.
    private func move() {
        let legacy = Self.legacyBlobs(in: defaults, spec: spec)
        let found = legacy.owners
        guard !found.isEmpty else {
            finishMove(keys: legacy.keys)
            return
        }
        for (owner, entries) in found {
            _ = place(owner, entries.merging(held?[owner] ?? [:]) { _, rows in rows })
        }
        keeper.mark = { [weak self] in
            (statements: [], landed: { self?.finishMove(keys: legacy.keys) })
        }
        write()
        Logger.library.notice("\(self.spec.label, privacy: .public) move owners=\(found.count) entries=\(found.values.map(\.count).reduce(0, +))")
    }

    private func finishMove(keys: [String]) {
        keeper.mark = nil
        for key in keys { defaults.removeObject(forKey: key) }
        for token in spec.legacyTokens { defaults.removeObject(forKey: token) }
        for key in defaults.dictionaryRepresentation().keys where spec.isLegacyVersion(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: spec.movedKey)
        Logger.library.notice("\(self.spec.label, privacy: .public) moved keys=\(keys.count); the blobs, the tokens and the versions are gone")
    }

    /// What a move found in the defaults: the entries by owner, and the keys
    /// they came from, which go once the rows landed.
    struct Legacy {
        var owners: [String: [String: Value]] = [:]
        var keys: [String] = []
    }

    /// Every blob of the spec's owners in the defaults, by its key, and the
    /// keys one per entry (`legacyPrefixes`) under the one owner of entries.
    /// A key that does not read stays in the defaults with a line.
    nonisolated static func legacyBlobs(in defaults: UserDefaults, spec: CarrierRowsSpec) -> Legacy {
        var found = Legacy()
        for key in defaults.dictionaryRepresentation().keys {
            if let prefix = spec.legacyPrefixes.first(where: { key.hasPrefix($0) }) {
                let entry = String(key.dropFirst(prefix.count))
                if let value = defaults.object(forKey: key) as? Value {
                    found.owners[CarrierRowsSpec.entryOwner, default: [:]][entry] = value
                } else if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Value.self, from: data) {
                    found.owners[CarrierRowsSpec.entryOwner, default: [:]][entry] = value
                } else {
                    Logger.library.error("\(spec.label, privacy: .public) move kept an unreadable key prefix=\(prefix, privacy: .public)")
                    continue
                }
                found.keys.append(key)
                continue
            }
            guard spec.isLegacyOwner(key) else { continue }
            if spec.wholeDocuments {
                // A document of the service was one body: it moves as the
                // owner's one entry. One that is no text stays where it is.
                guard let data = defaults.data(forKey: key), let text = String(data: data, encoding: .utf8),
                      let body = text as? Value else {
                    Logger.library.error("\(spec.label, privacy: .public) move kept a body that is no text owner=\(key, privacy: .public) bytes=\(defaults.data(forKey: key)?.count ?? 0)")
                    continue
                }
                found.owners[key] = [CarrierRowsSpec.bodyEntry: body]
            } else if let data = defaults.data(forKey: key) {
                // bearable, because an unreadable blob only costs a full pull; the truth lies on the other side and on the device
                found.owners[key] = (try? JSONDecoder().decode([String: Value].self, from: data)) ?? [:]
            } else if let dictionary = defaults.dictionary(forKey: key) as? [String: Value] {
                // The stamps of the choices were a property-list dictionary.
                found.owners[key] = dictionary
            }
            found.keys.append(key)
        }
        return found
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
    let movedKey: String
    /// Whether a blob before the rows was one whole document (the bodies of
    /// the Mär sync service), not a dictionary of entries.
    var wholeDocuments = false
    /// Keys one per entry before the rows (`jumpRing.<title>`): each moves
    /// as an entry of the one owner `entryOwner`, its title after the prefix.
    var legacyPrefixes: [String] = []

    /// The one entry of an owner that holds a whole document.
    static let bodyEntry = "body"
    /// The one owner of a kind whose entries are titles.
    static let entryOwner = ""

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
        movedKey: "carrierStandsMoved")

    static let records = CarrierRowsSpec(
        table: "carrier_record", label: "CARRIERRECORD",
        legacyOwners: ["cloudChoiceMirror", "cloudChoiceQueue", "cloudPlaylistMirror", "cloudPlaylistQueue",
                       "cloudStatsMirror", "cloudStatsQueue"],
        legacyScopedOwners: [],
        legacyTokens: ["cloudChoiceToken", "cloudPlaylistToken", "cloudStatsToken"], legacyScopedVersions: [],
        movedKey: "carrierRecordsMoved")

    /// The stamps of the choices (`UserChoiceCloudSync`): not a carrier's
    /// mirror but the family's bookkeeping, one moment per travelling
    /// choice. An owner here is the account whose choices the stamps date
    /// (`""` before any); the blob moves under its own name, and the family
    /// hands it to the holder of the choices.
    static let stamps = CarrierRowsSpec(
        table: "choice_stamp", label: "CHOICESTAMP",
        legacyOwners: ["userChoiceStamps"], legacyScopedOwners: [],
        legacyTokens: [], legacyScopedVersions: [],
        movedKey: "choiceStampsMoved")

    /// The playlists and choices documents of the Mär sync service and the
    /// bodies written but not yet taken, per identity: one owner per old
    /// key, its one entry the body (`bodyEntry`). The versions beside them
    /// go with the move.
    static let documents = CarrierRowsSpec(
        table: "carrier_document", label: "CARRIERDOCUMENT",
        legacyOwners: [],
        legacyScopedOwners: ["maerSyncPlaylists", "maerSyncPlaylistsPending", "maerSyncChoices", "maerSyncChoicesPending"],
        legacyTokens: [], legacyScopedVersions: ["maerSyncPlaylistsVersion", "maerSyncChoicesVersion"],
        movedKey: "carrierDocumentsMoved", wholeDocuments: true)

    /// The last backward jumps of each book, kept for the diagnosis on its
    /// page: one entry per title. Not a carrier's, it stays on the device.
    static let jumpRings = CarrierRowsSpec(
        table: "item_jump_ring", label: "JUMPRING",
        legacyOwners: [], legacyScopedOwners: [], legacyTokens: [], legacyScopedVersions: [],
        movedKey: "jumpRingsMoved", legacyPrefixes: ["jumpRing."])

    /// The offline copy of the server's bookmarks of each book: one entry
    /// per title. Not a carrier's, it stays on the device.
    static let bookmarks = CarrierRowsSpec(
        table: "item_bookmark", label: "BOOKMARKCACHE",
        legacyOwners: [], legacyScopedOwners: [], legacyTokens: [], legacyScopedVersions: [],
        movedKey: "bookmarkCacheMoved", legacyPrefixes: ["bookmarkCache."])
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

/// The stamps of the choices, one moment per owner and travelling choice.
typealias ChoiceStampRows = CarrierRows<Double>

extension CarrierRows where Value == Double {
    static var shared: ChoiceStampRows { CarrierRowStores.stamps }
    static func matching(_ defaults: UserDefaults) -> ChoiceStampRows { CarrierRowStores.matching(defaults, spec: .stamps) }
    convenience init(database: MaerDatabase, defaults: UserDefaults) {
        self.init(spec: .stamps, database: database, defaults: defaults)
    }
    /// The owner the blob of the stamps moved under, until the family hands
    /// it to the holder of the choices.
    nonisolated static var legacyOwner: String { "userChoiceStamps" }
    nonisolated static var movedKey: String { CarrierRowsSpec.stamps.movedKey }
}

/// The documents of the Mär sync service, one body per owner.
typealias CarrierDocumentRows = CarrierRows<String>

extension CarrierRows where Value == String {
    static var shared: CarrierDocumentRows { CarrierRowStores.documents }
    static func matching(_ defaults: UserDefaults) -> CarrierDocumentRows { CarrierRowStores.matching(defaults, spec: .documents) }
    convenience init(database: MaerDatabase, defaults: UserDefaults) {
        self.init(spec: .documents, database: database, defaults: defaults)
    }
    nonisolated static var movedKey: String { CarrierRowsSpec.documents.movedKey }
    nonisolated static func isLegacyOwner(_ key: String) -> Bool { CarrierRowsSpec.documents.isLegacyOwner(key) }

    /// An owner's document, nil when it holds none.
    func body(_ owner: String) -> Data? {
        rows(owner)[CarrierRowsSpec.bodyEntry].map { Data($0.utf8) }
    }

    /// An owner's document as it is now; nil removes it. A body that is no
    /// text (the service writes JSON) is not written: the row before stays,
    /// and a line says so, so a body never leaves without a word.
    func setBody(_ owner: String, _ body: Data?) {
        guard let body else {
            set(owner, [:])
            return
        }
        guard let text = String(data: body, encoding: .utf8) else {
            Logger.library.error("\(self.spec.label, privacy: .public) body is no text, the row before stays owner=\(owner, privacy: .public) bytes=\(body.count)")
            return
        }
        set(owner, [CarrierRowsSpec.bodyEntry: text])
    }
}

/// The last backward jumps of each book, one entry per title.
typealias JumpRingRows = CarrierRows<[[Double]]>
/// The offline copy of each book's bookmarks, one entry per title.
typealias BookmarkCacheRows = CarrierRows<[ABSBookmark]>

extension CarrierRows where Value == [[Double]] {
    static func matching(_ defaults: UserDefaults) -> JumpRingRows { CarrierRowStores.matching(defaults, spec: .jumpRings) }
    nonisolated static var movedKey: String { CarrierRowsSpec.jumpRings.movedKey }
}

extension CarrierRows where Value == [ABSBookmark] {
    static func matching(_ defaults: UserDefaults) -> BookmarkCacheRows { CarrierRowStores.matching(defaults, spec: .bookmarks) }
    nonisolated static var movedKey: String { CarrierRowsSpec.bookmarks.movedKey }
}

/// The app's six stores, and for a witness's own defaults a database file
/// of their own, named in that domain, so a second session on the same
/// domain finds the rows the first one wrote.
@MainActor
enum CarrierRowStores {
    /// The one database of the app, named once for every store below.
    private static let database = MaerDatabase.shared
    static let stands = CarrierStandRows(spec: .stands, database: database, defaults: AppStorageKeys.store)
    static let records = CarrierRecordRows(spec: .records, database: database, defaults: AppStorageKeys.store)
    static let stamps = ChoiceStampRows(spec: .stamps, database: database, defaults: AppStorageKeys.store)
    static let documents = CarrierDocumentRows(spec: .documents, database: database, defaults: AppStorageKeys.store)
    static let jumpRings = JumpRingRows(spec: .jumpRings, database: database, defaults: AppStorageKeys.store)
    static let bookmarks = BookmarkCacheRows(spec: .bookmarks, database: database, defaults: AppStorageKeys.store)

    /// The entries of a book that left the library go with it: its jump
    /// ring and the offline copy of its bookmarks (the copy was never
    /// cleaned up before). Only with a FULL library list, by the rule of
    /// `AppStorageKeys.cleanupPerBookKeys`.
    static func cleanupPerBookRows(validItemIds: Set<String>, in defaults: UserDefaults = .standard) {
        let gone: (String) -> Bool = { AppStorageKeys.prunedByBookCleanup($0, validItemIds: validItemIds) }
        JumpRingRows.matching(defaults).removeEntries(CarrierRowsSpec.entryOwner, where: gone)
        BookmarkCacheRows.matching(defaults).removeEntries(CarrierRowsSpec.entryOwner, where: gone)
    }

    static func matching<Value>(_ defaults: UserDefaults, spec: CarrierRowsSpec) -> CarrierRows<Value> {
        if defaults === AppStorageKeys.store {
            // Only the six app stores exist for the app's own defaults.
            let app: AnyObject = switch spec.table {
            case CarrierRowsSpec.stands.table: stands
            case CarrierRowsSpec.stamps.table: stamps
            case CarrierRowsSpec.documents.table: documents
            case CarrierRowsSpec.jumpRings.table: jumpRings
            case CarrierRowsSpec.bookmarks.table: bookmarks
            default: records
            }
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
