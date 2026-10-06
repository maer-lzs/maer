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
    /// down and read back, the holding says `replacing`, and only then the
    /// family replaces its stock by the rest of `scope` (nil: none rests,
    /// the family starts empty and its carrier fills it) for that owner.
    ///
    /// A holding that still says `replacing` from a run before ends that
    /// replacement first, without laying the half replaced stock over the
    /// rest. `before`: what the family lays down outside the shelf for the
    /// holder, before the shelf's rest; it throws when that did not land.
    /// `begunHere`: the family began that replacement in this run
    /// itself and its writes are still landing; its stock is the new
    /// owner's. A family whose replacement lands at once calls `settle`
    /// right after, one that writes later once its writes landed.
    func handOver<Value: Codable & Equatable>(
        _ family: String, to scope: String, unread: Bool, begunHere: Bool = false,
        before: (_ holder: String) throws -> Void = { _ in },
        current: () -> Value, replace: (_ rest: Value?, _ owner: String) throws -> Void
    ) throws -> HandOver {
        guard let holding = try holding(of: family) else {
            try setHolding(.init(owner: scope), of: family)
            return .first
        }
        let unfinished = holding.replacing && !begunHere
        guard unfinished || holding.owner != scope else { return .kept }
        // An unread stock would join the replaced one once it is read.
        if unread { return .unread }
        if unfinished {
            try replace(rest(Value.self, of: family, owner: holding.owner), holding.owner)
        }
        guard holding.owner != scope else { return .moved }
        // What a family keeps elsewhere (the credentials, which never touch
        // a file) rests first; a failure there replaces nothing.
        try before(holding.owner)
        try lay(current(), of: family, owner: holding.owner)
        try setHolding(.init(owner: scope, replacing: true), of: family)
        try replace(rest(Value.self, of: family, owner: scope), scope)
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

    /// The replacement for `scope` landed: the holding says so, unless
    /// another switch began meanwhile.
    func settle(_ family: String, owner scope: String) throws {
        guard try holding(of: family) == Holding(owner: scope, replacing: true) else { return }
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
