// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Keeps a directory of data the app can fetch again out of iCloud and
/// device backups: downloads, kept covers, the catalogue stocks. The mark on
/// the directory covers every file written into it later, so it is set on
/// the directory once per start or write, never file by file.
nonisolated enum BackupExclusion {
    /// Marks `directory`. A failure is logged with `label`, the owner of the
    /// directory, and answered with false; the data stays where it is.
    @discardableResult
    static func mark(_ directory: URL, label: StaticString) -> Bool {
        var marked = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try marked.setResourceValues(values)
            return true
        } catch {
            Logger.library.error("BACKUP exclusion failed for \(String(describing: label), privacy: .public) reason=\(FailureReason.of(error), privacy: .public)")
            return false
        }
    }

    /// Whether `directory` carries the mark, read from the disk. A URL keeps
    /// the resource values it read once, so the cache goes first; otherwise
    /// a mark set through another URL of the same directory stays unseen.
    static func isMarked(_ directory: URL) -> Bool {
        var fresh = directory
        fresh.removeAllCachedResourceValues()
        // bearable, because a value that cannot be read answers "not marked".
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}
