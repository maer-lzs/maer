// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The mark a replacement of a family's rows writes WITH the new stock, in
/// the same transaction: the replacement's name (`RestingShelf.Holding`).
/// After a restart only this mark proves that the replacement landed; a
/// stock that merely differs from the holder's rest proves nothing.
nonisolated enum OwnerMark {
    static let table = "owner_mark"

    /// The statements that set the mark, to run inside the write's transaction.
    static func statements(family: String, replacement: String) -> [SQLiteConnection.Statement] {
        [.init("CREATE TABLE IF NOT EXISTS \(table) (family TEXT PRIMARY KEY, replacement TEXT NOT NULL)"),
         .init("""
             INSERT INTO \(table) (family, replacement) VALUES (?, ?)
             ON CONFLICT(family) DO UPDATE SET replacement = excluded.replacement
             """, [.text(family), .text(replacement)])]
    }

    /// Whether the mark of `replacement` stands for `family`. False where the
    /// file or the table is not there (nothing landed); it throws when they
    /// cannot be read, and the hand-over then holds.
    static func stands(family: String, replacement: String, database: MaerDatabase) throws -> Bool {
        guard let reader = try database.readerNow() else { return false }
        let exists = try reader.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)])
        guard !exists.isEmpty else { return false }
        let rows = try reader.query("SELECT replacement FROM \(table) WHERE family = ?", [.text(family)])
        return rows.first?["replacement"]?.string == replacement
    }
}
