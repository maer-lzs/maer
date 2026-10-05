// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog
import SwiftUI   // Array.move(fromOffsets:toOffset:) for the reorder API
import WidgetKit

/// Global user-managed "Up Next" queue across ALL media types. Audiobooks
/// (raw ids), podcast episodes (`rss:`/`abspod:`) and music (`sub:album:` /
/// `sub:song:`, an album being one multi-track item = one entry that plays its
/// songs as a group). Persisted locally. Semantics = "launchpad, not playlist":
/// the currently playing item is NEVER in the queue. It is removed the moment
/// it STARTS (see PlayerCoordinator.open); "Up Next" is therefore what comes
/// AFTER the current one. Invariant "heard = flies out": an item also leaves on
/// playback end, on an auto-continue jump, and on a MANUAL mark-as-played
/// (see `markedPlayed`).
@MainActor
final class PlayQueue: ObservableObject {
    static let shared = PlayQueue(
        persists: true,
        database: MaerDatabase.shared,
        equivalents: { ABSPodcastProvider.shared.equivalentIds($0) }
    )

    @Published private(set) var ids: [String] = []

    /// The queue lives as ONE row (`upNext` in `play_queue`): it is one
    /// ordered list, replaced whole on every change, so a row per entry
    /// would only add position bookkeeping.
    nonisolated static let rowKey = "upNext"
    /// `shared` persists to the row + refreshes the widget; test instances
    /// stay in memory and touch neither disk nor database.
    private let persists: Bool
    private let keeper: RowKeeper<[String]>?
    /// An id → all its equivalent ids (podcast rss/abspod twins), so a removal
    /// takes out BOTH faces of the same episode. Injected → the core stays
    /// testable and uncoupled from ABSPodcastProvider.
    private let equivalents: (String) -> [String]

    init(persists: Bool = false,
         database: MaerDatabase? = nil,
         equivalents: @escaping (String) -> [String] = { [$0] }) {
        self.persists = persists
        self.keeper = persists ? database.map { RowKeeper(database: $0, table: .playQueue, label: "QUEUE") } : nil
        self.equivalents = equivalents
        if persists { load() }
    }

    /// The row; a failed read starts empty with the base unknown.
    private func load() {
        guard let keeper else {
            Logger.library.error("QUEUE start: persisting without a database, nothing loads")
            return
        }
        ids = keeper.startNow()?[Self.rowKey] ?? []
        // One row: a queue this run wrote is the newer word over the row read
        // after a failed start, so nothing of that row goes into memory.
        keeper.adopt = { _ in }
        Logger.library.notice("QUEUE start: entries=\(self.ids.count)")
    }

    /// Waits for every queued write of the row (tests, teardown).
    func awaitPendingWrites() async {
        await keeper?.awaitPendingWrites()
    }

    var first: String? { ids.first }
    var isEmpty: Bool { ids.isEmpty }

    /// Contains the id OR any of its equivalents (podcast twins).
    func contains(_ id: String) -> Bool {
        let eq = Set(equivalents(id))
        return ids.contains { eq.contains($0) || $0 == id }
    }

    /// To the very front (play next). Any existing occurrence (incl. a twin) is
    /// pulled to the front rather than duplicated.
    /// Radio stations NEVER enter the queue. Play only
    /// replaces the active playback. Pure rule, tested.
    nonisolated static func canEnqueue(_ id: String) -> Bool {
        !id.hasPrefix("radio:")
    }

    /// Text-only rss episodes never enter the queue.
    /// Even if some future call site forgets its own gate.
    private func isQueueable(_ id: String) -> Bool {
        PodcastSubscriptions.shared.isPlayableEpisode(itemId: id)
    }

    func playNext(_ id: String) {
        guard isQueueable(id) else { return }
        guard Self.canEnqueue(id) else { return }
        removeMatching(id)
        ids.insert(id, at: 0)
        save()
    }

    /// The way back hands the song it left to the orders, at the front and
    /// once, so "next" plays it again. The one door for that step; the rule
    /// decides which titles take it.
    func returnForNext(leaving left: String?) {
        guard let left, RemoteCommandRule.returnsWithNext(leaving: left) else { return }
        playNext(left)
    }

    /// To the end of the queue (no-op if already present under any face).
    func playLast(_ id: String) {
        guard isQueueable(id) else { return }
        guard Self.canEnqueue(id) else { return }
        guard !contains(id) else { return }
        ids.append(id)
        save()
    }

    /// Remove an item and its equivalents from the queue.
    func remove(_ id: String) {
        guard contains(id) else { return }
        removeMatching(id)
        save()
    }

    /// Invariant "heard = flies out": an item marked played (manually, on
    /// playback end, or on an auto-continue jump) leaves the queue. Same effect
    /// as `remove`, named for intent at the mark-played call sites.
    func markedPlayed(_ id: String) { remove(id) }

    func move(from source: IndexSet, to destination: Int) {
        ids.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Every entry in the form the server answers to (`NavidromeRekey`);
    /// returns how many entries changed. Saved only when something did.
    /// Nil while the start could not read the row: the row may hold the
    /// old ids this memory lacks, so the move waits for a start that reads.
    @discardableResult
    func rekey(_ map: (String) -> String) -> Int? {
        if keeper?.startReadFailed == true { return nil }
        let changed = NavidromeRekey.changedCount(ids, map)
        let rekeyed = NavidromeRekey.rekeyed(ids, map)
        guard rekeyed != ids else { return 0 }
        ids = rekeyed
        save()
        return changed
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids = []
        save()
    }

    /// Drops the id and all its equivalents from `ids` (no save).
    private func removeMatching(_ id: String) {
        let eq = Set(equivalents(id))
        ids.removeAll { eq.contains($0) || $0 == id }
    }

    /// The row gets the whole list; the keeper writes the diff and logs a
    /// failure, the queue lives on in memory and the next change writes
    /// again.
    private func save() {
        guard persists else { return }
        keeper?.write(emptying: .refused) { [weak self] in self.map { [Self.rowKey: $0.ids] } }
        writeWidgetSnapshot()
    }

    /// Write a queue preview (title + show/artist of the first entries) for the
    /// "Up Next" widget into the App Group container and refresh the widget.
    private func writeWidgetSnapshot() {
        let items = ids.prefix(6).compactMap { id -> PodcastQueueSnapshot.Item? in
            guard let item = AppSession.shared.libraryItem(forId: id) else { return nil }
            return PodcastQueueSnapshot.Item(title: item.title, show: item.media?.metadata?.authorName)
        }
        PodcastQueueSnapshot(items: items).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "PodcastUpNext")
    }
}

/// Pure cross-media auto-continue rule (testable core of
/// `PlayerCoordinator.nextPlayableQueueItem`). Returns the first queued id that
/// can start now. Scanning in order, regardless of media type, so a book,
/// episode or album plays next as the queue dictates. Offline only downloaded
/// items are playable; ids that no longer resolve to a library item are
/// skipped rather than handed to the player.
nonisolated enum QueueContinuation {
    static func nextPlayable(ids: [String],
                             isPlayable: (String) -> Bool,
                             resolves: (String) -> Bool) -> String? {
        ids.first { isPlayable($0) && resolves($0) }
    }
}
