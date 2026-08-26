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
    /// e32454e/2100b09: the EXISTING progress channel now also carries the
    /// classes that have no server behind them — catalog works and local
    /// sideloads keep their position in the very same `localPosition` store,
    /// and the user's goal for these rounds is "identical state on all
    /// devices". A second channel for the same question would be exactly the
    /// second version we are abolishing everywhere else.
    ///
    /// Server-owned ids (ABS books) stay out: they travel with the server
    /// sync, which owns their truth.
    ///
    /// **Edge, deliberately not filtered:** a `local:` sideload only exists
    /// on the device that holds the file — its POSITION still travels. That
    /// is harmless and right: device B shows the book once the file is there,
    /// and then the position is already correct.
    private let podcastPrefixes = ["localPosition.rss:", "localPosition.abspod:",
                                   "localPosition.local:"]
        + FreeCatalog.allPrefixes.map { "localPosition.\($0)" }
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

    /// beff8bd: the reason goes through the ONE watch — every observer of this
    /// notification asks WHY, none re-implements the comparison.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            reconcile()
        }
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
                  let arr = Self.coerce(value), arr.count >= 2 else { continue }
            local[String(key.dropFirst(keyPrefix.count))] = arr
        }

        // iCloud blob (coerce defensively — KV store returns NSNumber arrays).
        var cloud: [String: [Double]] = [:]
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                if let arr = Self.coerce(value), arr.count >= 2 { cloud[id] = arr }
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
            let lts = ProgressMark.timestamp(local[id]) ?? -1
            let cts = ProgressMark.timestamp(cloud[id]) ?? -1
            // The winner brings position and timestamp; the marked duration
            // survives from EITHER side. A device on an older build writes
            // two-value marks with a fresh timestamp — without this it would
            // wipe the reference point on every reconcile, silently.
            // The FORM travels exactly like the duration: the winner brings its
            // own if it has one, otherwise the other side's survives. Without
            // passing it the merge would rebuild the entry from the LOSING
            // side and the form would never leave this device — measured, not
            // assumed (StartedFormAcrossDevicesTests).
            if cts > lts, let c = cloud[id] {
                toLocal[id] = ProgressMark.advancing(local[id], position: c[0],
                                                     duration: ProgressMark.markedDuration(c) ?? 0,
                                                     nowMs: c[1],
                                                     form: ProgressMark.markedForm(c))
            } else if lts > cts, let l = local[id] {
                toCloud[id] = ProgressMark.advancing(cloud[id], position: l[0],
                                                     duration: ProgressMark.markedDuration(l) ?? 0,
                                                     nowMs: l[1],
                                                     form: ProgressMark.markedForm(l))
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
        let lts = ProgressMark.timestamp(local) ?? -1
        let cts = ProgressMark.timestamp(cloud) ?? -1
        if cts > lts, let c = cloud {
            if local == nil { return .pushTombstone }
            return .adoptCloud(ProgressMark.advancing(local, position: c[0],
                                                      duration: ProgressMark.markedDuration(c) ?? 0,
                                                      nowMs: c[1],
                                                      form: ProgressMark.markedForm(c)))
        }
        if lts > cts, let l = local {
            return .pushLocal(ProgressMark.advancing(cloud, position: l[0],
                                                     duration: ProgressMark.markedDuration(l) ?? 0,
                                                     nowMs: l[1],
                                                     form: ProgressMark.markedForm(l)))
        }
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
