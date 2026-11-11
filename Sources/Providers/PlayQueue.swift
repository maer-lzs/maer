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
    static let shared: PlayQueue = PlayQueue(
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
    /// Whether the start missed the row (`RowChain.startIncomplete`).
    var startIncomplete: Bool { keeper?.startIncomplete == true }
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
        // After a failed start the memory holds only what this run added:
        // the row read on the first save keeps its entries behind them
        // instead of being replaced by them.
        keeper.adopt = { [weak self] read in
            guard let self, let row = read[Self.rowKey] else { return }
            let before = self.ids.count
            self.ids = Self.afterUnreadStart(run: self.ids, read: row, equivalents: self.equivalents)
            Logger.library.notice("QUEUE row read on save: run=\(before) kept=\(self.ids.count - before)")
        }
        Logger.library.notice("QUEUE start: entries=\(self.ids.count)")
    }

    /// The queue after a start that could not read its row, once the row
    /// reads: what this run put in, in its order, then every entry of the
    /// row it does not hold (a twin counts as held). The run removed
    /// nothing of the row, it never saw it.
    nonisolated static func afterUnreadStart(run: [String], read: [String],
                                             equivalents: (String) -> [String]) -> [String] {
        let held = Set(run.flatMap { equivalents($0) + [$0] })
        var seen = held
        var out = run
        for id in read where canHold(id) && !seen.contains(id) {
            out.append(id)
            seen.formUnion(equivalents(id) + [id])
        }
        return out
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

    /// What the queue and the context hold: what a list may hold, without
    /// a routine's rule. A rule is a list entry, never something to play;
    /// it becomes episodes at the routine's start (`RoutinePlayback`), so
    /// no saved order or context names one.
    nonisolated static func canHold(_ id: String) -> Bool {
        canEnqueue(id) && !ItemNamespace.isRoutineRule(id)
    }

    /// Text-only rss episodes never enter the queue.
    /// Even if some future call site forgets its own gate.
    private func isQueueable(_ id: String) -> Bool {
        PodcastSubscriptions.shared.isPlayableEpisode(itemId: id)
    }

    func playNext(_ id: String) {
        guard isQueueable(id) else { return }
        guard Self.canHold(id) else { return }
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
        guard Self.canHold(id) else { return }
        guard !contains(id) else { return }
        ids.append(id)
        save()
    }

    /// New episodes a refresh brought (`UpNextAuto.plan`): the top block
    /// before everything, the end block after, each in its own order, one
    /// write. Unlike `playNext`, nothing already queued moves: an entry that
    /// is there under any face is left where the person put it.
    func addArrivals(_ plan: UpNextAuto.Plan) {
        let fits = { (id: String) in self.isQueueable(id) && Self.canHold(id) && !self.contains(id) }
        var top: [String] = []
        for id in plan.top where fits(id) && !top.contains(id) { top.append(id) }
        var end: [String] = []
        for id in plan.end where fits(id) && !top.contains(id) && !end.contains(id) { end.append(id) }
        guard !top.isEmpty || !end.isEmpty else { return }
        ids = top + ids + end
        save()
        Logger.library.notice("QUEUE new episodes top=\(top.count) end=\(end.count)")
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

    /// Several titles marked played elsewhere at once (a sync, an import):
    /// all of them and their equivalents leave, with one write.
    func markedPlayed(_ ids: [String]) {
        var kept = self.ids
        for id in ids {
            let eq = Set(equivalents(id))
            kept.removeAll { eq.contains($0) || $0 == id }
        }
        guard kept != self.ids else { return }
        self.ids = kept
        save()
    }

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
    /// The widget loads nothing from the network, so the first entries'
    /// covers go along as thumbnails: written after the snapshot, then the
    /// widget refreshes once more; a cover that does not load leaves the
    /// placeholder.
    private func writeWidgetSnapshot() {
        var covered: [(id: String, name: String)] = []
        let items = ids.prefix(6).compactMap { id -> PodcastQueueSnapshot.Item? in
            guard let item = AppSession.shared.libraryItem(forId: id) else { return nil }
            var cover: String?
            if covered.count < PodcastQueueSnapshot.coveredCount {
                let name = WidgetCoverStore.upNext.name(for: id)
                covered.append((id, name))
                cover = name
            }
            return PodcastQueueSnapshot.Item(
                title: item.title, show: item.media?.metadata?.authorName, cover: cover,
                placeholder: MediaFamily.placeholderSymbol(for: id, markedForm: ListeningStore.startedForm(id)))
        }
        PodcastQueueSnapshot(items: items).save()
        Self.reloadUpNextWidget()
        Task {
            let wrote = await WidgetCoverWriter.write(covered, into: .upNext) {
                Set(PodcastQueueSnapshot.load()?.items.compactMap(\.cover) ?? [])
            }
            if wrote { Self.reloadUpNextWidget() }
        }
    }

    private static func reloadUpNextWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: "PodcastUpNext")
    }
}

/// Pure cross-media auto-continue rule (testable core of
/// `PlaybackAdvance.next`, read by the end of a title and by a skip). Returns the first queued id that
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
