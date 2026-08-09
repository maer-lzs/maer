// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Paket 2: Mär playlists across a person's own devices, via the same
/// `NSUbiquitousKeyValueStore` the podcast progress uses — deliberately, and
/// that is why there is only ONE iCloud switch: both share one 1 MB budget, so
/// two switches would suggest an independence that does not exist.
///
/// Storage follows the podcast pattern: ONE consolidated key instead of a key
/// per list (the store allows 1024 keys, and a person with many lists must not
/// run into that). Without the iCloud capability the store stays silent and
/// everything keeps working locally — no crash, no loss.
///
/// The decisions live in `MaerPlaylistMerge` (pure, tested); this type only
/// reads, writes and translates.
@MainActor
final class MaerPlaylistCloudSync {
    static let shared = MaerPlaylistCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let blobKey = "maerPlaylists"
    private let tombKey = "maerPlaylistTombstones"
    private init() {}

    private var didStart = false
    /// Must never exceed 1 — a second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
        store.synchronize()
        reconcile()
    }

    @objc private nonisolated func cloudChanged() {
        Task { @MainActor in reconcile() }
    }

    func reconcile() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let playlists = MaerPlaylists.shared

        var local = MaerPlaylistMerge.Snapshot(tombstones: MaerPlaylists.tombstones)
        for list in playlists.syncable {
            local.lists[list.id] = .init(name: list.name, updatedAt: list.updatedAt,
                                         itemIds: list.itemIds)
        }

        var cloud = MaerPlaylistMerge.Snapshot()
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                guard let dict = value as? [String: Any],
                      let name = dict["name"] as? String,
                      let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue,
                      let items = dict["items"] as? [String] else { continue }
                cloud.lists[id] = .init(name: name, updatedAt: updatedAt, itemIds: items)
            }
        }
        if let raw = store.dictionary(forKey: tombKey) {
            for (id, value) in raw {
                if let stamp = (value as? NSNumber)?.doubleValue { cloud.tombstones[id] = stamp }
            }
        }

        let outcome = MaerPlaylistMerge.merge(local: local, cloud: cloud)
        let changedLocally = outcome.lists != local.lists
            || !outcome.rescued.isEmpty
            || outcome.tombstones != local.tombstones
        if changedLocally {
            playlists.apply(merged: outcome.lists, rescued: outcome.rescued,
                            tombstones: outcome.tombstones, rescueName: Self.rescueName)
        }

        // Push only when the shared state differs from what iCloud holds —
        // an unconditional write would ping-pong between devices.
        if outcome.lists != cloud.lists || outcome.tombstones != cloud.tombstones {
            var blob: [String: Any] = [:]
            for (id, entry) in outcome.lists {
                blob[id] = ["name": entry.name, "updatedAt": entry.updatedAt, "items": entry.itemIds]
            }
            store.set(blob, forKey: blobKey)
            store.set(outcome.tombstones, forKey: tombKey)
            store.synchronize()
        }
        if changedLocally {
            Logger.library.notice("PLAYLIST-SYNC merged lists=\(outcome.lists.count) rescued=\(outcome.rescued.count)")
        }
    }

    /// The name a rescued version gets: it must say WHAT it is and WHEN it is
    /// from, because the user has to decide between two versions of the same
    /// list without remembering which device did what.
    nonisolated static func rescueName(_ entry: MaerPlaylistMerge.Entry) -> String {
        let date = Date(timeIntervalSince1970: entry.updatedAt)
        let text = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "\(entry.name) (version from \(text))")
    }
}
