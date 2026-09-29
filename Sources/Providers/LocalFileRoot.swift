// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Where the files of a local entry live.
///
/// Today every entry is a COPY in the app container. A later entry may be a
/// folder the person linked where it lies, kept by a bookmark (a subfolder is
/// one audiobook, beside the copy, and removing it only lets go of the
/// bookmark). The library asks here for every path it reads and
/// for what removing an entry does, so the second place arrives without the
/// readers learning about it.
protocol LocalFileRoot {
    /// The folder holding the entry's files; nil when it cannot be reached now.
    func folder(forEntry id: String) -> URL?
    /// What removing the entry does to its files: a copy goes with it, a
    /// linked folder stays where it is.
    func removeFiles(ofEntry id: String)
}

/// The container: `LocalAudio/<uuid>/`, where the import puts its copies.
struct LocalContainerRoot: LocalFileRoot {
    let audioDir: URL

    /// The folder of an import that is still being made (no entry yet).
    func folder(forUUID uuid: String) -> URL {
        audioDir.appendingPathComponent(uuid, isDirectory: true)
    }

    func folder(forEntry id: String) -> URL? {
        folder(forUUID: String(id.dropFirst("local:".count)))
    }

    func removeFiles(ofEntry id: String) {
        guard let folder = folder(forEntry: id) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            // The reason only: the folder's name is the entry's id, its
            // path is private. The entry leaves the index either way.
            Logger.library.error("LOCALLIB removing an entry's files failed reason=\(FailureReason.of(error), privacy: .public)")
        }
    }
}
