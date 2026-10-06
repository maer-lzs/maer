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
