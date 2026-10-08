// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The books the secondary audiobook sources put on the shelf in one round
/// (local files, a Subsonic or Jellyfin source set to audiobooks). A source
/// whose list could not be fetched keeps its books of the round before, and
/// a source whose progress could not be fetched keeps the bars it had: a
/// failure is no answer, so it empties nothing. A list that comes back empty
/// is an answer, and it empties that source.
nonisolated enum SecondaryShelf {
    /// One source of the round: its key (the owner of its item ids) and its
    /// two fetches.
    struct Source: Sendable {
        let key: String
        let items: @Sendable () async throws -> [LibraryItem]
        let progress: @Sendable () async throws -> [String: BookProgress]
    }

    /// The entries of this round. `owners` names the source of each entry
    /// of `previous`, so the books of a source that failed are found there.
    static func entries(of sources: [Source], previous: [LibraryEntry],
                        owners: [String: String]) async -> [LibraryEntry] {
        var known: [String: BookProgress] = [:]
        for entry in previous { if let progress = entry.progress { known[entry.id] = progress } }
        var entries: [LibraryEntry] = []
        for source in sources {
            let items: [LibraryItem]
            do {
                items = try await source.items()
            } catch {
                let kept = previous.filter { owners[$0.id] == source.key }.map(\.item)
                Logger.library.error("LIBRARY secondary items failed source=\(source.key, privacy: .public) kept=\(kept.count): \(FailureReason.of(error), privacy: .public)")
                items = kept
            }
            let fetched: [String: BookProgress]?
            do {
                fetched = try await source.progress()
            } catch {
                Logger.library.error("LIBRARY secondary progress failed, last known kept: \(FailureReason.of(error), privacy: .public)")
                fetched = nil
            }
            let progress = ProgressAnswer.of(fetched, known: known)
            entries += items.map { LibraryEntry(item: $0, progress: progress[$0.id]) }
        }
        return entries
    }
}
