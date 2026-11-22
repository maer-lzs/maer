// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The move of podcast lists into folders on this device: at the start of
/// the list sync and after every merge, so a list that arrives in the old
/// form moves too. The unheard episodes of a list go to the end of Up Next
/// once per device and list; the lists that moved are noted for the one
/// notice on this device.
@MainActor
enum PodcastFolderMigration {
    static func run(store: MaerPlaylists = .shared, queue: PlayQueue = .shared) {
        var enqueued = Set(AppStorageKeys.stringArray(AppStorageKeys.podcastFoldersEnqueued) ?? [])
        let moved = store.foldPodcastLists(
            isHeard: { ChapterEntryRules.heardToTheEnd(stored: ListeningStore.storedEntry($0)) },
            enqueue: { ids in ids.forEach(queue.playLast) },
            enqueuedBefore: &enqueued)
        guard !moved.isEmpty else { return }
        AppStorageKeys.set(Array(enqueued).sorted(), for: AppStorageKeys.podcastFoldersEnqueued)
        AppStorageKeys.set(true, for: AppStorageKeys.podcastFoldersNoticePending)
        Logger.library.notice("PODCAST folders: lists moved=\(moved.count)")
    }
}
