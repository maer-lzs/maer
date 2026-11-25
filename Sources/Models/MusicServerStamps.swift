// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// The kinds of rows a device keeps for a title on its own.
nonisolated enum MusicRowKind: String, CaseIterable, Codable, Sendable {
    case stand, download, queue, context, history
}

/// Which Subsonic server a device-only row of a Subsonic title was written
/// under. The ids carry no server, and two servers of one kind can hand out
/// the same id for two titles; the stamp lets a row written under one
/// server read as absent under another, and come back with its server.
nonisolated struct MusicServerStamps: Equatable, Sendable {
    /// Kind → id → server key; stored as this plain dictionary.
    private(set) var stamps: [String: [String: String]] = [:]

    init(stamps: [String: [String: String]] = [:]) {
        self.stamps = stamps
    }

    /// The one key of a server: host without case, a port that is not the
    /// default, the path without a trailing slash; the scheme does not
    /// count (`ServerAddressSwitch.serverKey`).
    static func key(of address: String) -> String? { ServerAddressSwitch.serverKey(of: address) }

    /// Only Subsonic ids carry a stamp: they name no server and collide
    /// between servers of one kind.
    static func isStamped(_ itemId: String) -> Bool { ItemNamespace.serverFamily(of: itemId) == .subsonic }

    /// A row of `kind` was written under `server`; without a server it is
    /// written unstamped, as before.
    mutating func stamp(_ itemId: String, kind: MusicRowKind, server: String?) {
        guard Self.isStamped(itemId) else { return }
        stamps[kind.rawValue, default: [:]][itemId] = server
    }

    /// The row was written under another server than `current`. An
    /// unstamped row and a device without a server read as before.
    func isElsewhere(_ itemId: String, kind: MusicRowKind, current: String?) -> Bool {
        guard let current, let stamp = stamps[kind.rawValue]?[itemId] else { return false }
        return stamp != current
    }

    func shown(_ ids: [String], kind: MusicRowKind, current: String?) -> [String] {
        ids.filter { !isElsewhere($0, kind: kind, current: current) }
    }

    /// The ids in the form `map` gives, with their stamps.
    mutating func rekey(_ map: (String) -> String) {
        stamps = stamps.mapValues { rows in
            Dictionary(rows.map { (map($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }
}

/// The device's register, held per defaults object beside the Subsonic
/// address it compares with; it lives on this device only and never
/// travels.
nonisolated enum MusicServerStampBook {
    private static let books = Mutex<[ObjectIdentifier: MusicServerStamps]>([:])
    static let storageKey = AppStorageKeys.musicServerStamps
    /// A register stored in another form: nobody can read it, so no stamp
    /// writes over it before it was read; it is said once per run.
    static func isUnreadable(in defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.object(forKey: storageKey) else { return false }
        return !(stored is [String: [String: String]])
    }

    private static let saidUnreadable = Mutex<Set<ObjectIdentifier>>([])

    private static func current(_ defaults: UserDefaults) -> String? {
        MusicServerStamps.key(of: defaults.string(forKey: AppStorageKeys.subsonicServerURL) ?? "")
    }

    private static func withBook<T: Sendable>(_ defaults: UserDefaults, _ body: (inout MusicServerStamps) -> T) -> T {
        books.withLock { all in
            let id = ObjectIdentifier(defaults)
            if all[id] == nil {
                // A register in another shape is no stamp: the rows read as before.
                all[id] = MusicServerStamps(stamps: defaults.dictionary(forKey: storageKey) as? [String: [String: String]] ?? [:])
            }
            return body(&all[id]!)
        }
    }

    private static func save(_ stamps: MusicServerStamps, in defaults: UserDefaults) {
        defaults.set(stamps.stamps, forKey: storageKey)
    }

    static func stamp(_ itemId: String, kind: MusicRowKind, in defaults: UserDefaults = .standard) {
        stamp([itemId], kind: kind, in: defaults)
    }

    /// Several rows of one kind, one write of the register.
    static func stamp(_ itemIds: [String], kind: MusicRowKind, in defaults: UserDefaults = .standard) {
        let stamped = itemIds.filter(MusicServerStamps.isStamped)
        guard !stamped.isEmpty else { return }
        // A register of another form is not overwritten: it stays for the
        // build that can read it, and the rows read as unstamped meanwhile.
        if isUnreadable(in: defaults) {
            if saidUnreadable.withLock({ $0.insert(ObjectIdentifier(defaults)).inserted }) {
                Logger.library.error("MUSICSTAMPS register unreadable: stored in another form, kept as it is, no stamp written")
            }
            return
        }
        let server = current(defaults)
        let changed: MusicServerStamps? = withBook(defaults) { book in
            let before = book
            for id in stamped { book.stamp(id, kind: kind, server: server) }
            return book == before ? nil : book
        }
        if let changed { save(changed, in: defaults) }
    }

    static func isElsewhere(_ itemId: String, kind: MusicRowKind, in defaults: UserDefaults = .standard) -> Bool {
        guard MusicServerStamps.isStamped(itemId), let server = current(defaults) else { return false }
        return withBook(defaults) { $0.isElsewhere(itemId, kind: kind, current: server) }
    }

    static func shown(_ ids: [String], kind: MusicRowKind, in defaults: UserDefaults = .standard) -> [String] {
        guard ids.contains(where: MusicServerStamps.isStamped), let server = current(defaults) else { return ids }
        return withBook(defaults) { $0.shown(ids, kind: kind, current: server) }
    }

    /// The stamps under the ids `map` gives; answers how many rows moved and
    /// how many there are, as every step of the move does.
    @discardableResult
    static func rekey(_ map: (String) -> String, in defaults: UserDefaults = .standard) -> (changed: Int, total: Int) {
        let (moved, changed, total) = withBook(defaults) { book in
            let rows = book.stamps.values.flatMap(\.keys)
            book.rekey(map)
            return (book, rows.filter { map($0) != $0 }.count, rows.count)
        }
        if changed > 0 { save(moved, in: defaults) }
        return (changed, total)
    }
}

/// The entries of a travelling list a device shows: a title whose server
/// is not set up here is hidden, not removed; it stays in the list and
/// shows again where its server is.
nonisolated enum PlaylistShown {
    static func entries(_ ids: [String], reason: (String) -> UnavailableReason?) -> [String] {
        ids.filter { id in
            if case .sourceNotConfigured = reason(id) { return false }
            return true
        }
    }

    /// The places in the whole list of entries picked among the shown ones.
    static func wholeOffsets(_ offsets: IndexSet, shown: [String], all: [String]) -> IndexSet {
        IndexSet(offsets.compactMap { shown.indices.contains($0) ? all.firstIndex(of: shown[$0]) : nil })
    }

    /// A place before a shown entry is the place before it in the whole
    /// list; after the last shown entry it is the end.
    static func wholeDestination(_ destination: Int, shown: [String], all: [String]) -> Int {
        guard shown.indices.contains(destination) else { return all.count }
        return all.firstIndex(of: shown[destination]) ?? all.count
    }
}
