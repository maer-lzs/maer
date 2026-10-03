// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stores read their rows and nothing else. The documents they kept
/// before the rows were last written by v2.9; every device runs a build
/// that poured them long ago, so no store reads them, pours them or sets
/// them aside any more. A name below that comes back into the sources is a
/// reader of a form nobody writes.
struct RetiredDocumentsFenceTests {
    nonisolated static let retired = [
        "library_cache.json", "pending_sync.json", "syncHistory.json", "lastchecked.json",
        "maer_playlists.json", "DownloadsMeta", "playback_context.json", "local_library.json",
        "play_queue.json", "podcast_queue.json", "podcast-listen-log.json", "listening_stats.json",
        "DocumentMigration", "settingAside", ".migrated\""
    ]

    @Test("kein Speicher liest, giesst oder legt ein Dokument von vor den Zeilen beiseite", .needsTheSources)
    func noStoreReadsARetiredDocument() throws {
        var found: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            for name in Self.retired where code.contains(name) {
                found.append("\(file.lastPathComponent): \(name)")
            }
        }
        #expect(found.isEmpty, "a retired document is read again: \(found.sorted())")
    }
}
#endif
