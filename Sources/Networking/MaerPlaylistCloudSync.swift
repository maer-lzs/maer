// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Mär playlists across a person's own devices, via the same
/// `NSUbiquitousKeyValueStore` the podcast progress uses. Deliberately, and
/// that is why there is only ONE iCloud switch: both share one 1 MB budget, so
/// two switches would suggest an independence that does not exist.
///
/// Storage follows the podcast pattern: ONE consolidated key instead of a key
/// per list (the store allows 1024 keys, and a person with many lists must not
/// run into that). Without the iCloud capability the store stays silent and
/// everything keeps working locally. No crash, no loss.
///
/// The decisions live in `MaerPlaylistMerge` (pure, tested); this type only
/// reads, writes and translates.
@MainActor
final class MaerPlaylistCloudSync {
    static let shared = MaerPlaylistCloudSync()

    private let store: any UserChoiceCloudStore = CloudKeyValue.store
    private let blobKey = "maerPlaylists"
    private let tombKey = "maerPlaylistTombstones"
    private init() {}

    private var didStart = false
    /// Must never exceed 1. A second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: CloudKeyValue.notificationObject)
        _ = store.synchronize()
        reconcile()
    }

    /// The reason goes through the ONE watch. Every observer of this
    /// notification asks WHY, none re-implements the comparison.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            reconcile()
        }
    }

    func reconcile() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let playlists = MaerPlaylists.shared

        var local = MaerPlaylistMerge.Snapshot(tombstones: MaerPlaylists.tombstones)
        for list in playlists.syncable {
            local.lists[list.id] = .init(name: list.name, updatedAt: list.updatedAt,
                                         itemIds: list.itemIds, titles: list.titles,
                                         nameUpdatedAt: list.nameUpdatedAt,
                                         snapshots: list.snapshots, device: Self.deviceName)
        }

        var cloud = MaerPlaylistMerge.Snapshot()
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                guard let dict = value as? [String: Any],
                      let name = dict["name"] as? String,
                      let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue,
                      let items = dict["items"] as? [String] else { continue }
                // Blobs written before the snapshots existed carry none.
                // Tolerated, like every other added field.
                let titles = (dict["titles"] as? [String: String]) ?? [:]
                cloud.lists[id] = .init(name: name, updatedAt: updatedAt, itemIds: items,
                                        titles: titles,
                                        nameUpdatedAt: (dict["nameUpdatedAt"] as? NSNumber)?.doubleValue,
                                        snapshots: Self.snapshots(fromBlob: dict["snapshots"]),
                                        device: dict["device"] as? String)
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
            // Every rescue says in the log WHY it exists: which list, both
            // clocks, both contents. Without that a copy on a person's
            // device is a riddle.
            for loser in outcome.rescued {
                let id = local.lists.first { $0.value == loser }?.key ?? cloud.lists.first { $0.value == loser }?.key ?? "?"
                let winner = outcome.lists[id]
                Logger.library.notice("PLAYLIST merge rescue list=\(id, privacy: .public) name=\(loser.name, privacy: .public) loser.t=\(Int(loser.updatedAt)) loser.device=\(loser.device ?? "-", privacy: .public) loser.items=\(loser.itemIds.count) hash=\(loser.itemIds.hashValue) winner.t=\(Int(winner?.updatedAt ?? 0)) winner.device=\(winner?.device ?? "-", privacy: .public) winner.items=\(winner?.itemIds.count ?? 0) hash=\(winner?.itemIds.hashValue ?? 0) reason=content-differs")
            }
            playlists.apply(merged: outcome.lists, rescued: outcome.rescued,
                            tombstones: outcome.tombstones, rescueName: Self.rescueName,
                            rescueReason: Self.rescueReason)
        }

        // Push only when the shared state differs from what iCloud holds.
        // An unconditional write would ping-pong between devices.
        if outcome.lists != cloud.lists || outcome.tombstones != cloud.tombstones {
            var blob: [String: Any] = [:]
            for (id, entry) in outcome.lists {
                var payload: [String: Any] = ["name": entry.name, "updatedAt": entry.updatedAt,
                                              "items": entry.itemIds, "titles": entry.titles,
                                              "snapshots": Self.blob(snapshots: entry.snapshots),
                                              "device": entry.device ?? Self.deviceName]
                // The name's clock travels with the list. Written only when
                // it exists, so pre-clock devices read the blob unchanged.
                if let nameUpdatedAt = entry.nameUpdatedAt {
                    payload["nameUpdatedAt"] = nameUpdatedAt
                }
                blob[id] = payload
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
        let device = entry.device ?? String(localized: "another device")
        return String(localized: "Copy of \(entry.name) (\(device), \(text))")
    }

    /// The line under a rescue copy's name: what happened, in one sentence.
    nonisolated static func rescueReason(_ entry: MaerPlaylistMerge.Entry) -> String {
        String(localized: "Both devices changed this list. This is the version that lost; rename it to keep it.")
    }

    /// This device, by the name the system hands out (see
    /// `DeviceIdentity`). Travels with every version, so a rescue copy can
    /// say where it came from.
    static var deviceName: String { DeviceIdentity.name }

    /// The snapshots as the key-value store carries them (plist types only).
    nonisolated static func blob(snapshots: [String: CarriedItem]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (id, carried) in snapshots {
            var payload: [String: Any] = ["title": carried.title, "source": carried.source]
            if let subtitle = carried.subtitle { payload["subtitle"] = subtitle }
            if let duration = carried.duration { payload["duration"] = duration }
            if let cover = carried.coverURL { payload["cover"] = cover }
            out[id] = payload
        }
        return out
    }

    nonisolated static func snapshots(fromBlob raw: Any?) -> [String: CarriedItem] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: CarriedItem] = [:]
        for (id, value) in dict {
            guard let payload = value as? [String: Any], let title = payload["title"] as? String else { continue }
            out[id] = CarriedItem(id: id, title: title, subtitle: payload["subtitle"] as? String,
                                  duration: (payload["duration"] as? NSNumber)?.doubleValue,
                                  coverURL: payload["cover"] as? String,
                                  source: payload["source"] as? String)
        }
        return out
    }
}
