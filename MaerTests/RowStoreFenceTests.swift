// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The rows have one home (`Sources/Storage`) and five stores that speak to
/// them (subscriptions, library, listen log, statistics, playlists) plus
/// the stand mirror. `SQLite3` is imported in the home only (one named exception:
/// foreign databases the import reads immutable over a URI); the
/// connection and the shared database are opened only by the stores; a
/// whole replace happens only in the home and on the migration paths.
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
    /// for its checkpoint; they hold no rows.
    // BESTAND OHNE EINZELGRUENDE: der Grund gilt kollektiv und steht darueber (die zwei
    // Lebenszyklus-Haken der App, die die Datenbank um ihren Checkpoint
    // bitten).
    nonisolated static let connectionStock: [String: Int] = [
        "PodcastListenLog.swift": 2, "ListeningStats.swift": 2, "PodcastSubscriptions.swift": 1, "MaerApp.swift": 2,
        "MaerPlaylists.swift": 1
    ]
    /// `replaceAll(` outside Storage: the migration paths only.
    // BESTAND OHNE EINZELGRUENDE: der Grund gilt kollektiv und steht darueber (die
    // Migrationspfade).
    nonisolated static let replaceAllStock: [String: Int] = [
        "LibraryViewModel.swift": 1, "PodcastSubscriptions.swift": 1, "PodcastListenLog.swift": 1, "ListeningStats.swift": 2,
        "MaerPlaylists.swift": 1
    ]

    @Test("SQLite3 nur in Storage, die Verbindung nur bei den Zeilen-Speichern, replaceAll nur beim Umzug")
    func rowsHaveOneHome() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isStorage(file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            if Self.sites(of: ["import SQLite3"], in: text) > 0, Self.sqliteImportStock[name] == nil {
                offenders.append("\(name): imports SQLite3")
            }
            let connections = Self.sites(of: ["SQLiteConnection(", "MaerDatabase.shared"], in: text)
            if connections > (Self.connectionStock[name] ?? 0) {
                offenders.append("\(name): \(connections) connection sites")
            }
            let replaces = Self.sites(of: ["replaceAll("], in: text)
            if replaces > (Self.replaceAllStock[name] ?? 0) {
                offenders.append("\(name): \(replaces) replaceAll sites")
            }
        }
        #expect(offenders.isEmpty, "rows past their home: \(offenders)")
        #expect(Self.sites(of: ["replaceAll("], in: "let n = try await rows.replaceAll(stock)\n// replaceAll( in a comment") == 1)
        #expect(Self.sites(of: ["SQLiteConnection(", "MaerDatabase.shared"], in: "let c = try MaerDatabase.shared.connection()") == 1)
    }
}
#endif
