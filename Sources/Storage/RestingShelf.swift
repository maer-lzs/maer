// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a family's stock rests while another account owns the device
/// (decision of 03.10.2026, a new beginning per account): the device shows
/// one account's stock, and the stock of every other account it held rests
/// here, one file per family and account, until that account comes back.
///
/// Nothing here deletes. A resting set is replaced only by the same
/// account's next rest, and a rest is read back before the family replaces
/// its stock, so a failed write leaves the stock where it was.
nonisolated struct RestingShelf: Sendable {
    let directory: URL

    /// Who holds a family's stock on the device, and whether the stock of
    /// the last switch is still being replaced: the rest of the old owner
    /// stands, the replacement by the new owner's stock did not yet land.
    struct Holding: Codable, Equatable {
        var owner: String
        var replacing: Bool = false
        /// While replacing: who held before, and the replacement's own name.
        /// A family that writes later writes the name with the new stock as
        /// its mark (`landed`); only that mark proves the replacement landed.
        var from: String? = nil
        var replacement: String? = nil
    }

    func holding(of family: String) throws -> Holding? {
        try read(Holding.self, at: file(family, "holding"))
    }

    func setHolding(_ holding: Holding, of family: String) throws {
        try write(holding, at: file(family, "holding"))
    }

    /// What rests for `owner`; nil when nothing does. A file that does not
    /// decode throws: an unreadable rest is no empty one.
    func rest<Value: Decodable>(_ type: Value.Type, of family: String, owner: String) throws -> Value? {
        try read(type, at: file(family, owner))
    }

    /// Every owner something rests for in `family` (the holding is none).
    /// No folder is no owner; a folder that cannot be listed throws.
    func owners(of family: String) throws -> [String] {
        let folder = directory.appendingPathComponent(family, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") && $0 != "holding.json" }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    /// Lays the stock down for `owner` and reads it back: it throws unless
    /// what stands in the file is what was handed in.
    func lay<Value: Codable & Equatable>(_ value: Value, of family: String, owner: String) throws {
        let url = file(family, owner)
        try write(value, at: url)
        guard try read(Value.self, at: url) == value else { throw NotLaid() }
    }

    struct NotLaid: Error {}

    /// What a hand-over did, for the family's log line.
    enum HandOver: Equatable {
        /// The stock already belongs to the account.
        case kept
        /// No holder yet: the first account takes the stock that is here.
        case first
        /// The family's stock is not read whole; nothing moved, the family
        /// holds its round.
        case unread
        /// The holder's stock rests, read back, and the account's replaced it.
        case moved
    }

    /// THE hand-over of a family's stock to the account signed in now
    /// (`scope`), the same for every family: the holder's stock is laid
    /// down and read back, the holding says `replacing` with the
    /// replacement's name, and only then the family replaces its stock by
    /// the rest of `scope` (nil: none rests, the family starts empty and its
    /// carrier fills it) for that owner, under that name.
    ///
    /// An unread stock holds every way out, also with the holder unchanged:
    /// it would join the replaced stock once read, or be published as the
    /// holder's; only the first holder is still named over it. No holding is
    /// the first account only when the device knew no owner before
    /// (`previous`); else that owner holds.
    ///
    /// A holding that still says `replacing` from a run before ends that
    /// replacement first. It landed only where the family's own mark says
    /// so (`landed` with the replacement's name); then what stands is the
    /// new owner's and settles. Without the mark it is replaced again, and
    /// never laid over the rest. `issuedHere`: the replacements begun in
    /// this run, whose writes may still be landing; their stock is the new
    /// owner's. `before`: what the family lays down outside the shelf for
    /// the holder, before the shelf's rest; it throws when that did not
    /// land. `current` is asked at the moment it is laid down, after any
    /// replacement of a run before ended.
    func handOver<Value: Codable & Equatable>(
        _ family: String, to scope: String, previous: String? = nil, unread: Bool,
        issuedHere: Set<String> = [],
        landed: (_ replacement: String) throws -> Bool = { _ in false },
        before: (_ holder: String) throws -> Void = { _ in },
        current: () throws -> Value,
        replace: (_ rest: Value?, _ owner: String, _ replacement: String) throws -> Void
    ) throws -> HandOver {
        var found = try holding(of: family)
        if found == nil {
            // Naming the holder moves nothing, so it stands even over an
            // unread stock: the account before this one when the device knew
            // one, else this one. A later round then meets that holder.
            let holder = previous.flatMap { $0 == scope ? nil : $0 } ?? scope
            try setHolding(.init(owner: holder), of: family)
            if holder == scope { return unread ? .unread : .first }
            found = Holding(owner: holder)
        }
        if unread { return .unread }
        guard let holding = found else { return .unread }
        let begunHere = holding.replacement.map(issuedHere.contains) ?? false
        let unfinished = holding.replacing && !begunHere
        guard unfinished || holding.owner != scope else { return .kept }
        var replaced = false
        if unfinished {
            if let name = holding.replacement, try landed(name) {
                try settle(family, owner: holding.owner, replacement: name)
            } else {
                replaced = true
                let name = UUID().uuidString
                try setHolding(.init(owner: holding.owner, replacing: true, from: holding.from, replacement: name),
                               of: family)
                try replace(rest(Value.self, of: family, owner: holding.owner), holding.owner, name)
            }
        }
        // Settling what had landed moves nothing.
        guard holding.owner != scope else { return replaced ? .moved : .kept }
        // What a family keeps elsewhere (the credentials, which never touch
        // a file) rests first; a failure there replaces nothing.
        try before(holding.owner)
        try lay(current(), of: family, owner: holding.owner)
        let name = UUID().uuidString
        try setHolding(.init(owner: scope, replacing: true, from: holding.owner, replacement: name), of: family)
        try replace(rest(Value.self, of: family, owner: scope), scope, name)
        return .moved
    }

    /// Whether a family that follows the holder of another family may run
    /// (gpodder follows the subscriptions: its account is the device's, not
    /// the sync account's). It takes the holder it first meets and rests
    /// while another account holds, so it never carries one account's stock
    /// into another's.
    func follows(_ family: String, holderOf other: String) throws -> Bool {
        guard let holder = try holding(of: other)?.owner else { return true }
        guard let own = try holding(of: family)?.owner else {
            try setHolding(.init(owner: holder), of: family)
            return true
        }
        return own == holder
    }

    /// `family` follows the holder of `other` from now on: the person chose
    /// to go on with the account that holds it. No holder of `other` leaves
    /// `family` as it is.
    func adopt(_ family: String, holderOf other: String) throws {
        guard let holder = try holding(of: other)?.owner else { return }
        try setHolding(.init(owner: holder), of: family)
    }

    /// The replacement for `scope` landed: the holding says so, unless
    /// another switch or replacement began meanwhile (`replacement`: the
    /// name of the one that landed; nil settles any for `scope`).
    func settle(_ family: String, owner scope: String, replacement: String? = nil) throws {
        guard let holding = try holding(of: family), holding.owner == scope, holding.replacing,
              replacement == nil || holding.replacement == replacement else { return }
        try setHolding(.init(owner: scope), of: family)
    }

    private func file(_ family: String, _ name: String) -> URL {
        directory.appendingPathComponent(family, isDirectory: true).appendingPathComponent("\(name).json")
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<Value: Encodable>(_ value: Value, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
