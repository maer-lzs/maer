// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The one way a document is set aside after its rows were written: it is
/// moved to `<name>.migrated`, never deleted, so a wrong move is a rename
/// back. An earlier `.migrated` gives way to the newer document.
nonisolated enum DocumentMigration {
    static func setAside(_ document: URL) throws {
        let aside = document.appendingPathExtension("migrated")
        if FileManager.default.fileExists(atPath: aside.path) {
            try FileManager.default.removeItem(at: aside)
        }
        try FileManager.default.moveItem(at: document, to: aside)
    }
}
