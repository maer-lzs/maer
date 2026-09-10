// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The transport behind the Mär playlists. A carrier holds what the far
/// side has and takes what this device merged, nothing more: the merge
/// itself (per entry, newest name, rescue copies for the unknown) stays
/// the ONE rule in `MaerPlaylistMerge`, and the reconcile loop stays in
/// `MaerPlaylistCloudSync`. The key-value store is the first carrier; the
/// Mär sync service and CloudKit hang in here after, the same three
/// answers the pot, the claim and the statistics give.
///
/// The unit is a `MaerPlaylistMerge.Snapshot` (every syncable list plus the
/// deletion tombstones), because the merge works per LIST and a carrier
/// that spoke single entries could not tell a deletion from a missing one.
@MainActor
protocol PlaylistCarrier: AnyObject {
    /// A short name for the log line that says which carrier runs.
    var name: String { get }
    /// What the far side holds, as far as this carrier knows.
    func held() -> MaerPlaylistMerge.Snapshot
    /// Store the merged state. The carrier writes only when it differs from
    /// what it holds; an unconditional write would ping-pong between devices.
    func store(_ snapshot: MaerPlaylistMerge.Snapshot)
    /// Starts delivery. `onChange` fires on main whenever the far side moved;
    /// the runner re-reads, merges and decides.
    func start(onChange: @escaping @MainActor () -> Void)
    /// One round of asking the far side now. The key-value store delivers
    /// by itself, so there it only nudges.
    func refresh(by caller: String) async
}

/// Which carrier the playlists run on: the Mär sync service when the person
/// set one up, the key-value store otherwise. The same question the pot,
/// the claim and the statistics ask, answered the same way. The service and
/// CloudKit carriers arrive in the next slices; until then the answer is
/// always the key-value store.
@MainActor
enum PlaylistCarriers {
    static func make(access: MaerSyncAccess? = MaerSyncAccess.stored()) -> any PlaylistCarrier {
        // The service and CloudKit carriers are the next slices; the seam
        // is cut now so the runner never learns which way it is on.
        _ = access
        return KeyValuePlaylistCarrier()
    }
}

/// The key-value store as carrier: ONE consolidated blob (`maerPlaylists`)
/// plus the tombstones (`maerPlaylistTombstones`), via the same
/// `NSUbiquitousKeyValueStore` the podcast progress uses. One key, not a
/// key per list (the store allows 1024, and a person with many lists must
/// not run into that). Without the iCloud capability the store stays silent
/// and everything keeps working locally. The blob's plist shape lives here
/// and nowhere else, so a field added to a list is one place to teach.
@MainActor
final class KeyValuePlaylistCarrier: PlaylistCarrier {
    let name = "kvs"
    private let store: any UserChoiceCloudStore
    private let blobKey = "maerPlaylists"
    private let tombKey = "maerPlaylistTombstones"
    private var onChange: (@MainActor () -> Void)?
    /// Must never exceed 1. A second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    init(store: any UserChoiceCloudStore = CloudKeyValue.store) {
        self.store = store
    }

    /// This device, by the name the system hands out, as the fallback for a
    /// blob entry that carries none (a rescue copy has to say where it came
    /// from). See `DeviceIdentity`.
    static var deviceName: String { DeviceIdentity.name }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard observerRegistrations == 0 else { return }
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: CloudKeyValue.notificationObject)
        _ = store.synchronize()
    }

    func refresh(by caller: String) async {
        _ = store.synchronize()
    }

    /// The reason goes through the ONE watch. Every observer of this
    /// notification asks WHY, none re-implements the comparison.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.onChange?()
        }
    }

    func held() -> MaerPlaylistMerge.Snapshot {
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
                                        removed: Self.moments(fromBlob: dict["removed"]),
                                        added: Self.moments(fromBlob: dict["added"]),
                                        device: dict["device"] as? String)
            }
        }
        if let raw = store.dictionary(forKey: tombKey) {
            for (id, value) in raw {
                if let stamp = (value as? NSNumber)?.doubleValue { cloud.tombstones[id] = stamp }
            }
        }
        return cloud
    }

    func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
        var blob: [String: Any] = [:]
        for (id, entry) in snapshot.lists {
            var payload: [String: Any] = ["name": entry.name, "updatedAt": entry.updatedAt,
                                          "items": entry.itemIds, "titles": entry.titles,
                                          "snapshots": Self.blob(snapshots: entry.snapshots),
                                          "device": entry.device ?? Self.deviceName]
            // The name's clock travels with the list. Written only when it
            // exists, so pre-clock devices read the blob unchanged.
            if let nameUpdatedAt = entry.nameUpdatedAt {
                payload["nameUpdatedAt"] = nameUpdatedAt
            }
            if !entry.removed.isEmpty { payload["removed"] = entry.removed }
            if !entry.added.isEmpty { payload["added"] = entry.added }
            blob[id] = payload
        }
        store.set(blob, forKey: blobKey)
        store.set(snapshot.tombstones, forKey: tombKey)
        _ = store.synchronize()
    }

    /// Entry id → moment, from the blob. Blobs from before carry none.
    nonisolated static func moments(fromBlob raw: Any?) -> [String: Double] {
        var out: [String: Double] = [:]
        for (item, stamp) in (raw as? [String: Any]) ?? [:] {
            if let at = (stamp as? NSNumber)?.doubleValue { out[item] = at }
        }
        return out
    }

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
