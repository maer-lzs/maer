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
        fileURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("play_queue.json"),
        migrateFrom: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("podcast_queue.json"),
        persists: true,
        database: MaerDatabase.shared,
        equivalents: { ABSPodcastProvider.shared.equivalentIds($0) }
    )

    @Published private(set) var ids: [String] = []

    /// The queue lives as ONE row (`upNext` in `play_queue`): it is one
    /// ordered list, replaced whole on every change, so a row per entry
    /// would only add position bookkeeping. The documents in Documents (the
    /// queue's own, and before it the podcast-only one) are read only when
    /// the row holds nothing, poured into it once and set aside.
    nonisolated static let rowKey = "upNext"
    /// The seam to disk for the documents of the builds before: their
    /// directory and their names.
    private let ablage: Ablage
    private let documentName: String
    private let legacyURL: URL?
    /// `shared` persists to the row + refreshes the widget; test instances
    /// stay in memory and touch neither disk nor database.
    private let persists: Bool
    private let keeper: RowKeeper<[String]>?
    /// An id → all its equivalent ids (podcast rss/abspod twins), so a removal
    /// takes out BOTH faces of the same episode. Injected → the core stays
    /// testable and uncoupled from ABSPodcastProvider.
    private let equivalents: (String) -> [String]

    /// - Parameter migrateFrom: the podcast-only queue file of the builds
    ///   before; adopted once when neither the row nor the queue's own
    ///   document holds anything.
    init(fileURL: URL,
         migrateFrom legacyURL: URL? = nil,
         persists: Bool = false,
         database: MaerDatabase? = nil,
         equivalents: @escaping (String) -> [String] = { [$0] }) {
        self.ablage = Ablage(directory: fileURL.deletingLastPathComponent())
        self.documentName = fileURL.lastPathComponent
        self.legacyURL = legacyURL
        self.persists = persists
        self.keeper = persists ? database.map { RowKeeper(database: $0, table: .playQueue, label: "QUEUE") } : nil
        self.equivalents = equivalents
        if persists { load() }
    }

    /// The row first; the documents only when the row holds nothing, poured
    /// into it once. A failed row read falls back to the document that was
    /// set aside and migrates nothing.
    private func load() {
        guard let keeper else {
            Logger.library.error("QUEUE start: persisting without a database, nothing loads")
            return
        }
        let start = keeper.startNow()
        // An emptied queue is an empty row, not a missing one, so a
        // document beside it is never poured over it again.
        var loaded: [String]? = start.rows.map { $0[Self.rowKey] ?? [] }
        var documents: [URL] = []
        if loaded == nil {
            // Corrupt is kept aside by the seam and never buried by an empty
            // save; a missing file asks the podcast-only queue of before.
            if let current = ablage.loadNow([String].self, name: documentName).value {
                loaded = current
                documents = [ablage.url(for: documentName)]
            } else if let legacyURL,
                      let legacy = Ablage(directory: legacyURL.deletingLastPathComponent())
                          .loadNow([String].self, name: legacyURL.lastPathComponent).value {
                loaded = legacy
                documents = [legacyURL]
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow([String].self, name: documentName + ".migrated").value
                documents = []
            }
        }
        ids = loaded ?? []
        Logger.library.notice("QUEUE start: entries=\(self.ids.count) migrate=\(!documents.isEmpty)")
        if !documents.isEmpty { keeper.pour([Self.rowKey: ids], settingAside: documents) }
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
        keeper?.write([Self.rowKey: ids])
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
/// items are playable (A3); ids that no longer resolve to a library item are
/// skipped rather than handed to the player.
nonisolated enum QueueContinuation {
    static func nextPlayable(ids: [String],
                             isPlayable: (String) -> Bool,
                             resolves: (String) -> Bool) -> String? {
        ids.first { isPlayable($0) && resolves($0) }
    }
}
