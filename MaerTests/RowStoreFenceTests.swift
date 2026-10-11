// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rows have one home (`Sources/Storage`) and the stores that speak to
/// them (subscriptions, library, listen log, statistics, playlists, and the
/// stores behind `RowKeeper`) plus the stand mirror. `SQLite3` is imported
/// in the home only (one named exception: foreign databases the import
/// reads immutable over a URI); the connection and the shared database are
/// opened only by the stores; a whole replace happens only in the home and
/// on the migration paths; a store that moved a document reads and writes
/// its rows through the keeper, not by hand.
struct RowStoreFenceTests {

    nonisolated static func sites(of tokens: [String], in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && tokens.contains { trimmed.contains($0) }
            }.count
    }

    nonisolated static func isStorage(_ path: String) -> Bool { path.contains("/Sources/Storage/") }

    /// Files outside Storage that may import SQLite3, with the reason.
    nonisolated static let sqliteImportStock: [String: String] = [
        "PodcastImport.swift": "foreign databases (Apple Podcasts, AntennaPod) opened immutable over a URI; the reader is for the app's own file"
    ]
    /// `SQLiteConnection(` and `MaerDatabase.shared` outside Storage. The
    /// app's two lifecycle hooks (background, termination) ask the database
    /// for its checkpoint through one door (`settleRows`); they hold no rows.
    // BESTAND OHNE EINZELGRUENDE: der Grund gilt kollektiv und steht darueber (die eine
    // Tuer der zwei Lebenszyklus-Haken der App, die die Datenbank um ihren
    // Checkpoint bittet).
    nonisolated static let connectionStock: [String: Int] = [
        "MaerApp.swift": 1,
        "MaerPlaylists.swift": 1, "PlayQueue.swift": 1, "PlaybackContext.swift": 1, "SyncQueue.swift": 1,
        "SyncHistoryStore.swift": 1, "LocalLibrary.swift": 1, "DownloadManager.swift": 1
    ]
    /// `replaceAll(` outside Storage: empty, measured; the migrations that
    /// poured a document into the rows by hand are done.
    nonisolated static let replaceAllStock: [String: Int] = [:]
    /// `KeyedRowStore<` outside Storage: the stores that came before the
    /// keeper and still read and write their rows by hand. A store that
    /// moved a document since goes through `RowKeeper`, which holds the
    /// start read, the pour and the write chain once; the stock is the count.
    /// A type alias for the store counts as the store: every line that names
    /// the alias is a site. The totals read their two tables one by one, so
    /// a table that cannot be read leaves the other standing; that is where
    /// their stock grew.
    // BESTAND OHNE EINZELGRUENDE: der Grund gilt kollektiv und steht darueber (die
    // Speicher von vor der Naht).
    nonisolated static let keyedRowStoreStock: [String: Int] = [
        "ListeningStats.swift": 13
    ]

    /// `KeyedRowStore<` and every alias `code` declares for it.
    nonisolated static func keyedTokens(in code: String) -> [String] {
        ["KeyedRowStore<"] + code.matches(of: #/typealias\s+(\w+)\s*=\s*KeyedRowStore</#).map { String($0.1) }
    }

    @Test("SQLite3 nur in Storage, die Verbindung nur bei den Zeilen-Speichern, replaceAll nur beim Umzug")
    func rowsHaveOneHome() throws {
        var offenders: [String] = []
        var importers: Set<String> = []
        var connections: [String: Int] = [:]
        var replaces: [String: Int] = [:]
        var keyed: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isStorage(file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            if Self.sites(of: ["import SQLite3"], in: text) > 0 {
                importers.insert(name)
                if Self.sqliteImportStock[name] == nil { offenders.append("\(name): imports SQLite3") }
            }
            connections[name, default: 0] += Self.sites(of: ["SQLiteConnection(", "MaerDatabase.shared"], in: text)
            replaces[name, default: 0] += Self.sites(of: ["replaceAll("], in: text)
            keyed[name, default: 0] += Self.sites(of: Self.keyedTokens(in: text), in: text)
        }
        #expect(offenders.isEmpty, "rows past their home: \(offenders)")
        // An importer the stock names that imports nothing any more is a
        // claim about nothing.
        let quiet = Set(Self.sqliteImportStock.keys).subtracting(importers).sorted()
        #expect(quiet.isEmpty, "the stock names a file that imports SQLite3 no more: \(quiet)")
        let connectionDrift = StockDrift.findings(counts: connections, stock: Self.connectionStock)
        #expect(connectionDrift.isEmpty, "connection sites past their home, or a stock above the count: \(connectionDrift)")
        let replaceDrift = StockDrift.findings(counts: replaces, stock: Self.replaceAllStock)
        #expect(replaceDrift.isEmpty, "replaceAll past the migrations, or a stock above the count: \(replaceDrift)")
        let keyedDrift = StockDrift.findings(counts: keyed, stock: Self.keyedRowStoreStock)
        #expect(keyedDrift.isEmpty, "KeyedRowStore sites past the keeper (new stores go through RowKeeper), or a stock above the count: \(keyedDrift)")
        #expect(Self.sites(of: ["replaceAll("], in: "let n = try await rows.replaceAll(stock)\n// replaceAll( in a comment") == 1)
        #expect(Self.sites(of: ["SQLiteConnection(", "MaerDatabase.shared"], in: "let c = try MaerDatabase.shared.connection()") == 1)
        // Calibration: an alias counts as the store.
        let aliased = "typealias T = KeyedRowStore<Int>\nlet a: T.Load\nlet b = KeyedRowStore<Int>.self"
        #expect(Self.sites(of: Self.keyedTokens(in: aliased), in: aliased) == 3)
    }
}
#endif
