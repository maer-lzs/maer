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
    /// The chapter entry that plays now. It stays in `ids` until its end, so
    /// a restart finds it; every list a person sees and the advance read
    /// `shownIds`, which leave it out.
    @Published var running: String? {
        didSet { if persists, running != oldValue { writeWidgetSnapshot() } }
    }
    /// The entries a person sees and the advance may start.
    var shownIds: [String] { ChapterEntryRules.shown(ids, running: running) }

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
    /// Whether an id can be heard at all: a text-only rss episode cannot.
    /// Injected like `equivalents`, so a witness asks its own store.
    private let isPlayable: (String) -> Bool

    init(persists: Bool = false,
         database: MaerDatabase? = nil,
         equivalents: @escaping (String) -> [String] = { [$0] },
         isPlayable: @escaping (String) -> Bool = { PodcastSubscriptions.shared.isPlayableEpisode(itemId: $0) }) {
        self.persists = persists
        self.keeper = persists ? database.map { RowKeeper(database: $0, table: .playQueue, label: "QUEUE") } : nil
        self.equivalents = equivalents
        self.isPlayable = isPlayable
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
    /// A chapter entry plays as its book does.
    private func isQueueable(_ id: String) -> Bool {
        isPlayable(ItemNamespace.bookOrSelf(id))
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
    /// playback end, or on an auto-continue jump) leaves the queue, and a book
    /// heard to its end takes its chapter entries along.
    func markedPlayed(_ id: String) { markedPlayed([id]) }

    /// Several titles marked played elsewhere at once (a sync, an import):
    /// all of them, their equivalents and the chapter entries of a book
    /// among them leave, with one write. Starting a book or one of its
    /// chapters (`remove`) leaves its other chapters where they are.
    func markedPlayed(_ ids: [String]) {
        var kept = self.ids
        for id in ids {
            let eq = Set(equivalents(id)).union([id])
            kept.removeAll { eq.contains($0) || eq.contains(ItemNamespace.chapterEntry($0)?.bookId ?? "") }
        }
        guard kept != self.ids else { return }
        self.ids = kept
        save()
    }

    /// A chapter entry played to its end: it leaves, and the entry that
    /// follows it chapter by chapter (`ChapterEntryRules.follower`) joins the
    /// end, so the book and the rest of Up Next take turns.
    /// `played` is the chapter the entry really played, when a chain followed
    /// the book to another chapter (`ChapterEntryRules.playChapter`); its
    /// follower comes after that one. The end of a chain's last chapter
    /// finishes the book (`ChapterEntryRules.finishesBook`): its other
    /// chapters leave as for a book heard to its end.
    func chapterEnded(_ entryId: String, chapters: [ABSChapter], played: ABSChapter? = nil) {
        remove(entryId)
        guard let entry = ItemNamespace.chapterEntry(entryId) else { return }
        if let chapter = played ?? ChapterEntryRules.chapter(startMs: entry.startMs, in: chapters),
           ChapterEntryRules.finishesBook(entryId: entryId, chapter: chapter, chapters: chapters) {
            markedPlayed(entry.bookId)
            return
        }
        var asked = entryId
        if let played {
            asked = ItemNamespace.chapterEntryId(bookId: entry.bookId, startMs: ChapterEntryRules.ms(played.start),
                                                 continues: entry.continues)
        }
        guard let next = ChapterEntryRules.follower(of: asked, chapters: chapters) else { return }
        playLast(next)
    }

    /// Puts a book into Up Next chapter by chapter, at the end, starting at
    /// the chapter of its position (`ChapterEntryRules.chainStart`), and says
    /// what became of it.
    @discardableResult
    func enqueueChain(bookId: String, chapters: [ABSChapter], bookPosition: Double) -> ChapterEntryRules.ChainOutcome {
        guard chapters.count >= 2 else { return .notHeld }
        if ids.contains(where: { ItemNamespace.chapterEntry($0).map { $0.bookId == bookId && $0.continues } == true }) {
            return .waitsAlready
        }
        guard let start = ChapterEntryRules.chainStart(chapters: chapters, bookPosition: bookPosition) else {
            return .noChapterLeft
        }
        let id = ItemNamespace.chapterEntryId(bookId: bookId, startMs: ChapterEntryRules.ms(start.start), continues: true)
        guard isQueueable(id), Self.canHold(id) else { return .notHeld }
        ids.append(id)
        save()
        return .queued
    }

    func move(from source: IndexSet, to destination: Int) {
        ids.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// A move in a list that shows `shownIds`, carried onto `ids`.
    func move(shownFrom source: IndexSet, to destination: Int) {
        move(from: Self.actualOffsets(source, ids: ids, running: running),
             to: Self.actualDestination(destination, ids: ids, running: running))
    }

    /// The places in `ids` of places in `shownIds`, and of a destination
    /// among them: a shown place is the place of the same entry in the queue,
    /// the end of the shown list is the end of the queue.
    nonisolated static func actualOffsets(_ shown: IndexSet, ids: [String], running: String?) -> IndexSet {
        let places = shownPlaces(ids: ids, running: running)
        return IndexSet(shown.compactMap { $0 < places.count ? places[$0] : nil })
    }

    nonisolated static func actualDestination(_ shown: Int, ids: [String], running: String?) -> Int {
        let places = shownPlaces(ids: ids, running: running)
        return shown < places.count ? places[shown] : ids.count
    }

    /// The place in `ids` of each entry of `shownIds`, in order.
    nonisolated private static func shownPlaces(ids: [String], running: String?) -> [Int] {
        ids.indices.filter { ids[$0] != running }
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
        let items = shownIds.prefix(6).compactMap { id -> PodcastQueueSnapshot.Item? in
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
