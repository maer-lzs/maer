// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Syncs podcast progress (`localPosition`) across your own Apple devices via
/// iCloud — so "continue on the iPad" works without an ABS server too (and in
/// addition to it).
///
/// Storage: ONE consolidated `NSUbiquitousKeyValueStore` key holding a dict
/// `id → [position, updatedAtMs]` for ALL podcast ids (`rss:` + `abspod:`).
/// One key instead of thousands avoids the KV store's 1024-key limit.
///
/// Merge rule: per episode the newer `updatedAtMs` wins; the winner is written
/// back to the stale side (local OR iCloud). No ping-pong, because writes only
/// happen on a real timestamp lag.
///
/// Without the iCloud KV capability enabled the store stays silent — then
/// everything runs purely locally as before (no crash, no data loss).
@MainActor
final class PodcastCloudSync {
    static let shared = PodcastCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let blobKey = "podcastProgress"
    /// Sync only podcast positions — audiobook/local positions go via the
    /// server or are device-internal.
    private let podcastPrefixes = ["localPosition.rss:", "localPosition.abspod:"]
    private let keyPrefix = "localPosition."

    private init() {}

    /// Guard against double observer registration (start() can run again when
    /// the library view is recreated, e.g. logout→login) — a second observer
    /// would double every reconcile on external iCloud changes.
    private var didStart = false
    /// How many times the observer was actually registered — must never exceed
    /// 1 (exposed for tests).
    private(set) var observerRegistrations = 0

    /// Call once at app start: listen for iCloud changes + reconcile immediately.
    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()
        reconcile()
    }

    @objc private nonisolated func cloudChanged() {
        Task { @MainActor in reconcile() }
    }

    /// Merge local podcast positions and the iCloud blob (newest-wins) and bring
    /// both sides to the shared state.
    func reconcile() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let defaults = UserDefaults.standard

        // Collect local positions.
        var local: [String: [Double]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard podcastPrefixes.contains(where: { key.hasPrefix($0) }),
                  let arr = Self.coerce(value), arr.count == 2 else { continue }
            local[String(key.dropFirst(keyPrefix.count))] = arr
        }

        // iCloud blob (coerce defensively — KV store returns NSNumber arrays).
        var cloud: [String: [Double]] = [:]
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                if let arr = Self.coerce(value), arr.count == 2 { cloud[id] = arr }
            }
        }

        let outcome = Self.merge(local: local, cloud: cloud)
        for (id, value) in outcome.toLocal {
            defaults.set(value, forKey: keyPrefix + id)    // iCloud newer → local
        }
        if !outcome.toCloud.isEmpty {
            for (id, value) in outcome.toCloud { cloud[id] = value }   // local newer → iCloud
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        }
        if !outcome.toLocal.isEmpty {
            // Have the UI/sections and ABS provider display re-evaluate.
            PodcastProgressStore.shared.reload()
            // Personen-Ebene: reconciled transitions land in the listen log.
            PodcastListenLog.shared.noteReconciled(guids: outcome.toLocal.keys)
        }
        // F9: record full-scan merges that moved anything (single-key writes
        // stay out — they would flood the ring buffer).
        if !outcome.toLocal.isEmpty || !outcome.toCloud.isEmpty {
            SyncHistoryStore.shared.append(SyncHistory.entry(
                service: .iCloud, direction: .both,
                counters: [.init(key: .positionsDown, value: outcome.toLocal.count),
                           .init(key: .positionsUp, value: outcome.toCloud.count)],
                duration: 0,
                deviceId: SyncHistoryStore.deviceId))
        } else {
            // Y48/Y50: a clean full-scan merge leaves no ring entry — still show
            // it ran via the "last checked" stamp.
            SyncHistoryStore.shared.noteChecked(.iCloud)
        }
    }

    /// Pure newest-wins merge (testable): per id the newer `updatedAtMs` wins;
    /// equal timestamps produce NO write on either side (no ping-pong).
    nonisolated static func merge(local: [String: [Double]], cloud: [String: [Double]])
        -> (toLocal: [String: [Double]], toCloud: [String: [Double]]) {
        var toLocal: [String: [Double]] = [:]
        var toCloud: [String: [Double]] = [:]
        for id in Set(local.keys).union(cloud.keys) {
            let lts = local[id]?[1] ?? -1
            let cts = cloud[id]?[1] ?? -1
            if cts > lts, let c = cloud[id] {
                toLocal[id] = c
            } else if lts > cts, let l = local[id] {
                toCloud[id] = l
            }
        }
        return (toLocal, toCloud)
    }

    /// Decision of the single-id merge (pure, testable). Matches `merge` for
    /// value-vs-value cases; the local-nil case deliberately differs from the
    /// full scan: a deleted local key means "mark unplayed", so instead of
    /// restoring the old cloud value a fresh zero tombstone is pushed.
    enum SingleMergeOutcome: Equatable {
        case adoptCloud([Double])
        case pushLocal([Double])
        case pushTombstone
        case none
    }

    nonisolated static func mergeSingle(local: [Double]?, cloud: [Double]?) -> SingleMergeOutcome {
        let lts = (local?.count == 2) ? local![1] : -1
        let cts = (cloud?.count == 2) ? cloud![1] : -1
        if cts > lts, let c = cloud {
            if local == nil { return .pushTombstone }
            return .adoptCloud(c)
        }
        if lts > cts, let l = local { return .pushLocal(l) }
        return .none
    }

    /// Targeted single-episode merge — for the frequent per-write callers
    /// (mark played/unplayed, position saves). The full `reconcile()` enumerates
    /// the ENTIRE UserDefaults per call, which is far too expensive to run per
    /// episode (mark-all on a 200-episode show = 200 full scans).
    func reconcile(changedId id: String) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard id.hasPrefix("rss:") || id.hasPrefix("abspod:") else { return }
        let defaults = UserDefaults.standard
        var cloud: [String: Any] = store.dictionary(forKey: blobKey) ?? [:]

        let localArr = defaults.array(forKey: keyPrefix + id).flatMap { Self.coerce($0) }
        let cloudArr = (cloud[id]).flatMap { Self.coerce($0) }
        switch Self.mergeSingle(local: localArr, cloud: cloudArr) {
        case .adoptCloud(let value):
            defaults.set(value, forKey: keyPrefix + id)
            PodcastProgressStore.shared.reload()
            PodcastListenLog.shared.noteReconciled(guids: [id])
        case .pushLocal(let value):
            cloud[id] = value
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        case .pushTombstone:
            // Local delete (mark unplayed) wins only with a fresh timestamp we
            // don't have — write an explicit zero so other devices follow.
            cloud[id] = [0.0, Date().timeIntervalSince1970 * 1000]
            store.set(cloud, forKey: blobKey)
            store.synchronize()
        case .none:
            break
        }
    }

    /// `[Double]` from a plist value (array of `Double`/`NSNumber`).
    private static func coerce(_ value: Any) -> [Double]? {
        if let d = value as? [Double] { return d }
        if let n = value as? [NSNumber] { return n.map(\.doubleValue) }
        return nil
    }
}
