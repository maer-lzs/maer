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
    /// Store the merged state. The runner decides whether to store at all
    /// (an unconditional write would ping-pong between devices); a carrier
    /// that compares per list before writing asks `MaerPlaylistMerge.differs`.
    func store(_ snapshot: MaerPlaylistMerge.Snapshot)
    /// Starts delivery. `onChange` fires on main whenever the far side moved;
    /// the runner re-reads, merges and decides.
    func start(onChange: @escaping @MainActor () -> Void)
    /// The runner took another carrier: from now on this one stores,
    /// fetches and delivers nothing.
    func stop()
    /// One round of asking the far side now. The key-value store delivers
    /// by itself, so there it only nudges.
    func refresh(by caller: String) async
}

/// Which carrier the playlists run on: the Mär sync service when the person
/// set one up, otherwise CloudKit on a device (the key-value store as its
/// fallback and legacy reader), and the key-value store alone on a DEBUG
/// simulator so no test writes a person's CloudKit container. The same
/// question the pot, the claim and the statistics ask, answered the same way.
@MainActor
enum PlaylistCarriers {
    static func make(access: MaerSyncAccess?) -> any PlaylistCarrier {
        make(read: access.map { .access($0) } ?? .absent)
    }

    /// An unknown access keeps the family with the service (`servesFamilies`).
    static func make(read: MaerSyncAccessRead = MaerSyncAccess.read()) -> any PlaylistCarrier {
        if read.servesFamilies { return MaerSyncPlaylistCarrier(session: MaerSyncCarriers.session) }
        let keyValue = KeyValuePlaylistCarrier()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" { return keyValue }
        #endif
        return CloudKitPlaylistCarrier(database: CKPlaylistDatabase(), fallback: keyValue)
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
    nonisolated static let listsKey = "maerPlaylists"
    private let blobKey = listsKey
    private let tombKey = "maerPlaylistTombstones"
    private var onChange: (@MainActor () -> Void)?
    /// Must never exceed 1. A second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    private let roomLimitBytes: Int
    private let onRefusal: @MainActor (RoomLimit.Reckoning) -> Void

    /// `roomLimitBytes` is the ceiling the lists and their tombstones must
    /// fit under together, and `onRefusal` is where they are said out loud
    /// when they do not; a witness passes a small ceiling and a recorder.
    init(store: any UserChoiceCloudStore = CloudKeyValue.store,
         roomLimitBytes: Int = RoomLimit.potLimitBytes,
         onRefusal: @escaping @MainActor (RoomLimit.Reckoning) -> Void = { CloudQuotaWatch.refuse(pot: listsKey, $0) }) {
        self.store = store
        self.roomLimitBytes = roomLimitBytes
        self.onRefusal = onRefusal
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
        guard !stopped else { return }
        let signpost = PerfSignpost.syncRound(.playlists, .keyValue)
        defer { signpost.end() }
        _ = store.synchronize()
    }

    func stop() {
        stopped = true
        onChange = nil
        NotificationCenter.default.removeObserver(self)
    }
    private var stopped = false

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
                if let entry = Self.entry(from: value) { cloud.lists[id] = entry }
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
        guard !stopped else { return }
        var blob: [String: Any] = [:]
        for (id, entry) in snapshot.lists {
            // The blob names this device for a list that carries no device.
            blob[id] = Self.payload(of: entry, device: entry.device ?? Self.deviceName)
        }
        // The ceiling is reckoned BEFORE the write, both keys together: the
        // store refuses what does not fit without a word, and half a write
        // (lists without their tombstones) would bring a deleted list back.
        if let refused = RoomLimit.refusal(writing: [blobKey: blob, tombKey: snapshot.tombstones],
                                           beside: store.dictionaryRepresentation, limit: roomLimitBytes) {
            Logger.library.error("KVS write REFUSED key=\(self.blobKey, privacy: .public) lists=\(blob.count) bytes=\(refused.bytes) others=\(refused.otherBytes) limit=\(refused.limit)")
            onRefusal(refused)
            return
        }
        store.set(blob, forKey: blobKey)
        store.set(snapshot.tombstones, forKey: tombKey)
        _ = store.synchronize()
    }

    /// THE shape of one list on every wire (this blob, the service, the
    /// CloudKit record): one pair, so a field written is a field read. The
    /// device is the wire's own convention and comes in: the blob names
    /// this device, the service writes an empty name, CloudKit leaves it
    /// out. Optional fields are written only when they exist, so a device
    /// from before reads the shape unchanged.
    nonisolated static func payload(of entry: MaerPlaylistMerge.Entry, device: String?) -> [String: Any] {
        var payload: [String: Any] = ["name": entry.name, "updatedAt": entry.updatedAt,
                                      "items": entry.itemIds, "titles": entry.titles,
                                      "snapshots": blob(snapshots: entry.snapshots)]
        if let device { payload["device"] = device }
        if let nameUpdatedAt = entry.nameUpdatedAt { payload["nameUpdatedAt"] = nameUpdatedAt }
        if !entry.removed.isEmpty { payload["removed"] = entry.removed }
        if !entry.added.isEmpty { payload["added"] = entry.added }
        return payload
    }

    /// The list back from that shape, tolerant: a field from later or
    /// missing from before reads as none, an empty device name as none.
    /// nil when name, clock or items are missing.
    nonisolated static func entry(from raw: Any?) -> MaerPlaylistMerge.Entry? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue,
              let items = dict["items"] as? [String] else { return nil }
        let device = dict["device"] as? String
        return .init(name: name, updatedAt: updatedAt, itemIds: items,
                     titles: (dict["titles"] as? [String: String]) ?? [:],
                     nameUpdatedAt: (dict["nameUpdatedAt"] as? NSNumber)?.doubleValue,
                     snapshots: snapshots(fromBlob: dict["snapshots"]),
                     removed: moments(fromBlob: dict["removed"]),
                     added: moments(fromBlob: dict["added"]),
                     device: (device?.isEmpty ?? true) ? nil : device)
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
