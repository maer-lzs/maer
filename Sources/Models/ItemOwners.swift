// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which Audiobookshelf server a library id belongs to: the one whose last
/// full load named it. A library id carries no server, so on a device that
/// knew more than one server this is the only way to tell whose book left.
///
/// The register lives beside the id, on this device only, never in a
/// carrier: the ids stay as they are everywhere they are kept or travel.
/// An id no full load named has no owner, and an id without an owner is
/// never cleaned: not knowing is no ownership.
nonisolated struct ItemOwners: Codable, Equatable, Sendable {
    /// Library id → the server's one name (`ABSServerScope.identity`).
    private(set) var owners: [String: String] = [:]

    init(owners: [String: String] = [:]) {
        self.owners = owners
    }

    func owner(of itemId: String) -> String? { owners[itemId] }

    /// A full load of `server` named `ids`: they are its now, also an id
    /// another server named before (the last full load to name it wins).
    /// Ids with a namespace name their source themselves and stay out.
    /// Answers whether anything changed.
    @discardableResult
    mutating func noteFullLoad(ids: Set<String>, server: String) -> Bool {
        let name = ABSServerScope.identity(of: server)
        var changed = false
        for id in ids where ItemNamespace.of(id) == nil && owners[id] != name {
            owners[id] = name
            changed = true
        }
        return changed
    }

    /// The ids a full load of `server` cleans on a device that knew more
    /// than one server: those it owns that its list no longer names. An id
    /// of another server and an id without an owner stay.
    func cleanable(absentFrom listed: Set<String>, server: String) -> Set<String> {
        let name = ABSServerScope.identity(of: server)
        return Set(owners.filter { $0.value == name && !listed.contains($0.key) }.map(\.key))
    }

    /// The cleaned ids leave with their state, so the register names no
    /// book that is gone. Answers whether anything changed.
    @discardableResult
    mutating func drop(where gone: (String) -> Bool) -> Bool {
        let before = owners.count
        owners = owners.filter { !gone($0.key) }
        return owners.count != before
    }
}
