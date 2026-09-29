// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one way a document is set aside after its rows were written: it is
/// moved to `<name>.migrated`, never deleted, so a wrong move is a rename
/// back. An earlier `.migrated` gives way to the newer document.
///
/// A set-aside document leaves the backup: it is megabytes the rows now
/// hold (the library cache up to 6 MB, the subscriptions up to 77 MB
/// measured), and it dies with the release after next. The rule for every
/// migration from here on: in this release the exclusion, in the next the
/// removal, and every migration names its own removal in its report.
nonisolated enum DocumentMigration {
    static func setAside(_ document: URL) throws {
        var aside = document.appendingPathExtension("migrated")
        if FileManager.default.fileExists(atPath: aside.path) {
            try FileManager.default.removeItem(at: aside)
        }
        try FileManager.default.moveItem(at: document, to: aside)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try aside.setResourceValues(values)
        } catch {
            // The move stands; a document that stays in the backup costs
            // space, not data, and the line says which one.
            Logger.library.error("MIGRATED backup exclusion failed name=\(aside.lastPathComponent, privacy: .public) reason=\(String(describing: error), privacy: .public)")
        }
    }

    /// Whether a file carries the exclusion, for the witness.
    static func isExcludedFromBackup(_ url: URL) -> Bool {
        // bearable, because an error reading the attribute counts as "not excluded", which the witness then reports red
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }
}
