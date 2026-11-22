// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Downloads audiobooks while you listen (`AudiobookPreload` decides): the
/// book started now, the books of Continue Listening and, with its switch,
/// the next book of a finished series, on Wi-Fi only, within the chosen
/// space. It records its own downloads and touches nothing downloaded by
/// hand. Finished automatic books go a day later, also with the switch
/// off and without Wi-Fi: deleting spends nothing.
@MainActor
enum AudiobookPreloader {
    /// What the download while listening itself downloaded.
    static var owned: Set<String> {
        get { Set(AppStorageKeys.stringArray(AppStorageKeys.audiobookAutoDownloadedIds) ?? []) }
        set { AppStorageKeys.set(Array(newValue).sorted(), for: AppStorageKeys.audiobookAutoDownloadedIds) }
    }

    /// The runs form a chain, one at a time (`SendChain`). The entries start
    /// each in a task of their own; a second run beside the first would not
    /// see the books the first one is loading, neither in the space nor in
    /// `owned`, and its write of `owned` would drop the first one's books.
    private static let runs = SendChain()

    /// Runs `body` after every run started before it.
    static func chained(_ body: @escaping @MainActor () async -> Void) async {
        await runs.run {
            await body()
            return 0
        }
    }

    /// One run: after a book starts (`started`), after one finished
    /// (`finished`, for the next of its series) and at the app's start.
    static func run(started: String? = nil, finished: String? = nil,
                    library: LibraryViewModel = AppSession.shared.libraryViewModel,
                    router: ItemRouter = .live) async {
        await chained {
            await once(started: started, finished: finished, library: library, router: router)
        }
    }

    private static func once(started: String?, finished: String?,
                             library: LibraryViewModel, router: ItemRouter) async {
        let dm = DownloadManager.shared
        let enabled = AppStorageKeys.bool(AppStorageKeys.audiobookPreloadEnabled, default: false)
        let onWiFi = await NetworkStatus.isOnWiFi()
        // Ids downloaded by the automatism and deleted by hand since are no
        // longer its own.
        var mine = owned.filter { dm.isDeletableDownload(itemId: $0) }
        let held = mine.map { book(id: $0, bytes: dm.downloadSize(forItemId: $0), duration: dm.loadCachedDetail(forItemId: $0)?.media.duration) }
        var wanted: [AudiobookPreload.Book] = []
        var details: [String: LibraryItemDetail] = [:]
        if AudiobookPreload.mayLoad(enabled: enabled, onWiFi: onWiFi) {
            let series = finished.flatMap { id in
                AppStorageKeys.bool(AppStorageKeys.audiobookPreloadNextInSeries, default: false) ? library.nextInSeries(after: id)?.id : nil
            }
            let ids = AudiobookPreload.candidates(started: started, continueRow: library.continueListening.map(\.id), nextInSeries: series)
            for id in ids where MediaFamily.of(id) == .book && !dm.isDownloaded(itemId: id) && !dm.isDownloading(itemId: id) {
                // A source that cannot keep the book offline is not asked.
                let provider = router.provider(id)
                guard MediaDownloadOffer.isPossible(provider.capabilities, mayKeep: provider.mayKeep(itemId: id)) else { continue }
                do {
                    let detail = try await provider.fetchItemDetail(itemId: id)
                    // A book whose source names no file sizes cannot be held
                    // to the space: it is left out and said so.
                    let sizes = (detail.media.tracks ?? []).map { $0.metadata?.size }
                    guard !sizes.isEmpty, !sizes.contains(where: { $0 == nil }) else {
                        Logger.library.notice("PRELOAD book=\(id, privacy: .public) left out: no file sizes")
                        continue
                    }
                    details[id] = detail
                    wanted.append(book(id: id, bytes: sizes.compactMap { $0 }.reduce(0, +), duration: detail.media.duration))
                } catch {
                    Logger.library.error("PRELOAD book=\(id, privacy: .public) detail failed: \(FailureReason.of(error), privacy: .public)")
                }
            }
        }
        let gb = AppStorageKeys.int(AppStorageKeys.audiobookPreloadBudgetGB) ?? AudiobookPreload.defaultBudgetGB
        let plan = AudiobookPreload.plan(wanted: wanted, held: held,
                                         budgetBytes: AudiobookPreload.budgetBytes(gb: gb),
                                         freeBytes: dm.freeDiskBytes() ?? 0,
                                         nowMs: Date().timeIntervalSince1970 * 1000)
        for id in plan.remove {
            dm.deleteDownload(itemId: id)
            mine.remove(id)
        }
        Logger.library.notice("PRELOAD on=\(enabled) wifi=\(onWiFi) space=\(gb) held=\(held.count) wanted=\(wanted.count) fetch=\(plan.download.count) remove=\(plan.remove.count)")
        owned = mine
        for id in plan.download {
            guard let detail = details[id] else { continue }
            await dm.download(item: detail, provider: router.provider(id), kind: .audiobooks)
            if dm.isDeletableDownload(itemId: id) { owned.insert(id) }
        }
    }

    /// A book as the rule sees it: its size, the moment it was last heard
    /// and, once it is finished, that moment.
    private static func book(id: String, bytes: Int64, duration: Double?) -> AudiobookPreload.Book {
        let stored = ListeningStore.backup(id)
        let heardMs = ProgressMark.timestamp(stored) ?? 0
        let finished = stored.map {
            ProgressMark.isPlayed(stored: $0, currentDuration: duration ?? 0, tail: PlayedTail.seconds(forItemId: id))
        } ?? false
        return AudiobookPreload.Book(id: id, bytes: bytes, lastHeardMs: heardMs, finishedAtMs: finished ? heardMs : nil)
    }
}
