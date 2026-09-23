// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The counting line of the index runs outside the free catalogue: the
/// network questions a scrolled tile asks for itself (a playlist mosaic, an
/// artist's info and portrait). One line per network question, in the shape
/// of the catalogue's metadata line, so a device log counts runs and why
/// each one ended. Nothing about the runs changes here; this only makes
/// them countable before anything is built for them.
nonisolated enum IndexRunLine {
    static func line(kind: String, ms: Int, reason: String) -> String {
        "INDEXRUN kind=\(kind) ms=\(ms) reason=\(reason)"
    }

    /// Runs `work` and writes its line. The id is the server's own and goes
    /// to the log only as a hash, enough to count questions per id. The
    /// answer is handed back as `try?` did: nil on any failure.
    static func measured<T>(_ kind: String, id: String,
                            _ work: () async throws -> T) async -> T? {
        let started = Date()
        do {
            let value = try await work()
            write(kind: kind, id: id, started: started, reason: "ok")
            return value
        } catch {
            write(kind: kind, id: id, started: started, reason: ArchiveOrgClient.fetchReason(error))
            return nil
        }
    }

    static func write(kind: String, id: String, started: Date, reason: String) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Logger.library.notice("\(line(kind: kind, ms: ms, reason: reason), privacy: .public) id=\(id, privacy: .private(mask: .hash))")
    }
}
