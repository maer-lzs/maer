// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import SwiftUI   // Array.move(fromOffsets:toOffset:) for the reorder API
import WidgetKit

/// Global user-managed "Up Next" queue across ALL media types — audiobooks
/// (raw ids), podcast episodes (`rss:`/`abspod:`) and music (`sub:album:` /
/// `sub:song:`, an album being one multi-track item = one entry that plays its
/// songs as a group). Persisted locally. Semantics = "launchpad, not playlist":
/// the currently playing item is NEVER in the queue — it is removed the moment
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
        equivalents: { ABSPodcastProvider.shared.equivalentIds($0) }
    )

    @Published private(set) var ids: [String] = []

    private let fileURL: URL
    /// `shared` persists to disk + refreshes the widget; test instances don't.
    private let persists: Bool
    /// An id → all its equivalent ids (podcast rss/abspod twins), so a removal
    /// takes out BOTH faces of the same episode. Injected → the core stays
    /// testable and uncoupled from ABSPodcastProvider.
    private let equivalents: (String) -> [String]

    /// - Parameter migrateFrom: legacy queue file (the podcast-only queue); its
    ///   entries are adopted once when the new file does not exist yet.
    init(fileURL: URL,
         migrateFrom legacyURL: URL? = nil,
         persists: Bool = false,
         equivalents: @escaping (String) -> [String] = { [$0] }) {
        self.fileURL = fileURL
        self.persists = persists
        self.equivalents = equivalents
        if let decoded = Self.load(fileURL) {
            ids = decoded
        } else if let legacyURL, let migrated = Self.load(legacyURL) {
            // One-time migration of the former podcast-only queue.
            ids = migrated
            if persists {
                save()
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    private static func load(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return decoded
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
    /// F3 (decided): radio stations NEVER enter the queue — play only
    /// replaces the active playback. Pure rule, tested.
    nonisolated static func canEnqueue(_ id: String) -> Bool {
        !id.hasPrefix("radio:")
    }

    func playNext(_ id: String) {
        guard Self.canEnqueue(id) else { return }
        removeMatching(id)
        ids.insert(id, at: 0)
        save()
    }

    /// To the end of the queue (no-op if already present under any face).
    func playLast(_ id: String) {
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

    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(ids) {
            try? data.write(to: fileURL, options: .atomic)
        }
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
/// can start now — scanning in order, regardless of media type, so a book,
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
