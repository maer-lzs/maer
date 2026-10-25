// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A book's progress diagnosis for the diagnostics page: where the book's
/// position could come from, each source with its timestamp, and which one
/// the start would take (`ProgressDiagnosis.bookReport`). Read-only, built
/// once when a book is tapped there.
@MainActor
enum BookProgressReport {
    /// The books the page offers: the one playing first, then the most
    /// recently heard, each once, at most `limit`.
    static func books(_ entries: [LibraryEntry], playingID: String?, limit: Int = 6) -> [LibraryEntry] {
        let heard = entries
            .filter { ($0.progress?.lastUpdate ?? 0) > 0 }
            .sorted { ($0.progress?.lastUpdate ?? 0) > ($1.progress?.lastUpdate ?? 0) }
        let playing = entries.first { $0.id == playingID }
        let ordered = (playing.map { [$0] } ?? []) + heard.filter { $0.id != playingID }
        return Array(ordered.prefix(limit))
    }

    static func text(for entry: LibraryEntry, downloadManager: DownloadManager = .shared) -> String {
        let saved = ListeningStore.backup(entry.id)
        let cached = downloadManager.loadCachedDetail(forItemId: entry.id)
        let flushed = ListeningStore.flushed(entry.id)
        let sources = ProgressDiagnosis.BookSources(
            serverPosition: entry.progress?.currentTime,
            serverUpdatedAtMs: entry.progress?.lastUpdate,
            localPosition: (saved?.count ?? 0) >= 2 ? saved?[0] : nil,
            localSavedAtMs: (saved?.count ?? 0) >= 2 ? saved?[1] : nil,
            cachedPosition: cached?.userMediaProgress?.currentTime,
            cachedUpdatedAtMs: cached?.userMediaProgress?.lastUpdate,
            flushedPosition: (flushed?.count ?? 0) >= 2 ? flushed?[0] : nil,
            flushedAtMs: (flushed?.count ?? 0) >= 2 ? flushed?[1] : nil,
            serverIsFinished: entry.progress?.isFinished,
            progressFraction: entry.progress?.fraction,
            jumpRing: JumpRingRows.matching(AppStorageKeys.store).entry(CarrierRowsSpec.entryOwner, entry.id) ?? [],
            duration: cached?.media.duration ?? entry.item.media?.duration ?? 0,
            isDownloaded: downloadManager.isDownloaded(itemId: entry.id),
            // There is no separate progress QUEUE (positions push directly);
            // what exists is the bookmark queue and the sync history. The
            // honest stand-in for "what does this device still owe".
            pendingSyncOperations: BookmarkQueue.shared.pendingOps()
                .filter { $0.itemId == entry.id }.count)
        return ProgressDiagnosis.bookReport(
            title: BookPageItem.shown(entry: entry.item, detail: cached).title,
            sources: sources,
            now: Date().timeIntervalSince1970,
            format: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard) },
            formatTime: { seconds in
                let total = Int(seconds.rounded())
                return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            })
    }
}
