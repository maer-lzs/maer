// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The runner of the Mär playlists across a person's own devices: it reads
/// the local lists, reads what the carrier holds, asks the ONE rule
/// (`MaerPlaylistMerge`) to unite them, applies the result and hands the
/// merged state back to the carrier. The transport is a `PlaylistCarrier`;
/// the key-value store is the first, sharing the ONE iCloud switch with the
/// podcast progress (one 1 MB budget, so a second switch would suggest an
/// independence that does not exist). The rule stays pure and tested; this
/// type only orchestrates.
@MainActor
final class MaerPlaylistCloudSync {
    static let shared = AccessFollowers.enrolled(MaerPlaylistCloudSync())

    private var carrier: any PlaylistCarrier
    private var generation = CarrierGeneration()
    private let playlists: MaerPlaylists
    /// An item id in the form the music server answers to (Navidrome's new
    /// ids); the identity where the rule does not hold. A witness hands in
    /// its own, so two devices on different builds can share one carrier.
    private let itemIdMap: (String) -> String
    /// This device, by the name the system hands out (see `DeviceIdentity`).
    /// Travels with every version, so a rescue copy can say where it came
    /// from. A witness hands in its own, so two devices can share one run.
    private let deviceName: () -> String
    /// The account signed in now (`MaerSyncIdentity.scope`), nil when none
    /// is: the lists follow it before a round (`MaerPlaylists.follow`).
    /// A witness hands in its own.
    private let identity: () -> String?
    private var didStart = false
    private var reconciling = false
    private var sendScheduled = false

    /// The carrier is chosen at start-up and again when the access changes
    /// (`follow`); a witness hands in a recording carrier and a store of
    /// its own.
    init(carrier: any PlaylistCarrier = PlaylistCarriers.make(),
         playlists: MaerPlaylists = .shared,
         itemIdMap: @escaping (String) -> String = { SubsonicProvider.canonicalItemId($0) },
         deviceName: @escaping () -> String = { DeviceIdentity.name },
         identity: @escaping () -> String? = { MaerSyncCarriers.session.identity?.scope }) {
        self.carrier = carrier
        self.playlists = playlists
        self.itemIdMap = itemIdMap
        self.deviceName = deviceName
        self.identity = identity
    }

    func start() {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        startCarrier(by: "start")
        playlists.changed = { [weak self] in self?.noteLocalChange() }
        reconcile()
    }

    private func startCarrier(by caller: String) {
        Logger.library.notice("PLAYLIST-SYNC carrier=\(self.carrier.name, privacy: .public) by=\(caller, privacy: .public)")
        carrier.start(onChange: generation.guarded({ [weak self] in self?.generation }) { [weak self] in
            self?.reconcile()
        })
    }

    /// The carrier the access of this moment asks for, when it travels
    /// another way than the held one; see `PodcastCloudSync.follow`.
    func follow(_ next: @autoclosure () -> any PlaylistCarrier, signedIn: Bool, identityChanged: Bool = false, by caller: String) {
        guard CarrierWay.mustChange(holdsService: CarrierWay.isService(carrierName: carrier.name),
                                    signedIn: signedIn, identityChanged: identityChanged) else { return }
        carrier.stop()
        CarrierRefreshers.unregister(carrier)
        carrier = next()
        generation.advance()
        guard didStart else { return }
        startCarrier(by: caller)
        reconcile()
    }

    /// A local change (a list made, renamed, filled, emptied or deleted)
    /// reaches the carrier on the next turn of the main actor, not at the
    /// next start; the saves of one turn (a new list and its titles) become
    /// one reconcile. A change the reconcile applied itself is not a local
    /// change.
    func noteLocalChange() {
        guard !reconciling, !sendScheduled else { return }
        sendScheduled = true
        Task { [weak self] in
            self?.sendScheduled = false
            self?.reconcile()
        }
    }

    func reconcile() {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        reconciling = true
        defer { reconciling = false }
        let playlists = self.playlists
        // Another account than the lists' owner: its lists replace the
        // owner's first, or the round would carry them to it.
        if let scope = identity(), !playlists.follow(owner: scope) {
            Logger.library.notice("PLAYLIST-SYNC round held: the lists wait for their owner")
            return
        }
        let map = itemIdMap
        playlists.rekey(map)

        var local = MaerPlaylistMerge.Snapshot(tombstones: MaerPlaylists.tombstones)
        let device = deviceName()
        for list in playlists.syncable {
            local.lists[list.id] = .init(name: list.name, updatedAt: list.updatedAt,
                                         itemIds: list.itemIds, titles: list.titles,
                                         nameUpdatedAt: list.nameUpdatedAt,
                                         snapshots: list.snapshots, removed: list.removed,
                                         added: list.added, device: device)
        }

        // The carrier read with its entries in the form this device keeps.
        // An old form a device on an older build wrote stays there: written
        // is only what differs from this reading, or two builds would
        // answer each other on every round.
        let cloud = NavidromeRekey.playlists(carrier.held(), map)
        let outcome = MaerPlaylistMerge.merge(local: local, cloud: cloud)
        // The same answer as for the carrier below: the device name is no
        // change here either. The store keeps no device name, so a merge
        // that only took the other side's name has nothing to apply.
        let changedLocally = MaerPlaylistMerge.differs(outcome.snapshot, local) || !outcome.rescued.isEmpty
        if changedLocally {
            // Every rescue says in the log WHY it exists: which list, both
            // clocks, both contents. Without that a copy on a person's
            // device is a riddle. Only the ones the store will keep are
            // counted: the log used to say `rescued=1` for an empty loser
            // the store then dropped.
            let kept = playlists.playlists.map(\.itemIds)
            let rescued = outcome.rescued.filter { MaerPlaylistMerge.needsRescue($0, existing: kept) }
            for loser in rescued {
                let id = MaerPlaylistMerge.sourceId(of: loser, local: local, cloud: cloud) ?? "?"
                let winner = outcome.lists[id]
                Logger.library.notice("PLAYLIST merge rescue list=\(id, privacy: .public) name=\(loser.name, privacy: .public) loser.t=\(Int(loser.updatedAt)) loser.device=\(loser.device ?? "-", privacy: .public) loser.items=\(loser.itemIds.count) hash=\(loser.itemIds.hashValue) winner.t=\(Int(winner?.updatedAt ?? 0)) winner.device=\(winner?.device ?? "-", privacy: .public) winner.items=\(winner?.itemIds.count ?? 0) hash=\(winner?.itemIds.hashValue ?? 0) reason=content-differs")
            }
            playlists.apply(merged: outcome.lists, rescued: outcome.rescued,
                            tombstones: outcome.tombstones, rescueName: Self.rescueName,
                            rescueReason: Self.rescueReason)
        }

        // Hand the merged state back only when it differs from what the
        // carrier holds. An unconditional write would ping-pong between
        // devices; the carrier does not decide, it stores. The device name
        // is no difference: each device stamps its own, and comparing it
        // made two devices rewrite the same content after each other.
        if MaerPlaylistMerge.differs(outcome.snapshot, cloud) {
            carrier.store(outcome.snapshot)
        }
        if changedLocally {
            let kept = playlists.playlists.filter(\.isRescue).count
            Logger.library.notice("PLAYLIST-SYNC merged lists=\(outcome.lists.count) rescued=\(outcome.rescued.count) rescueCopies=\(kept)")
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
}

extension MaerPlaylistCloudSync: AccessFollower {
    var followerName: String { "playlists" }

    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        follow(PlaylistCarriers.make(), signedIn: signedIn, identityChanged: identityChanged, by: caller)
    }
}
