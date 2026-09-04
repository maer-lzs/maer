// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Syncs podcast progress (`localPosition`) across your own Apple devices via
/// iCloud. So "continue on the iPad" works without an ABS server too (and in
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
/// Without the iCloud KV capability enabled the store stays silent. Then
/// everything runs purely locally as before (no crash, no data loss).
@MainActor
final class PodcastCloudSync {
    static let shared = PodcastCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let blobKey = "podcastProgress"

    /// The one write of the blob. Says how big it is and whether the
    /// store took it: the key-value store refuses a value silently, and
    /// a sync that "does nothing" must leave a number in the log.
    private func writeBlob(_ cloud: [String: Any], by caller: String = #function) {
        // Writers arrive in bursts (play, seek, mark, foreground within
        // seconds). The store uploads the whole pot each time, and the
        // small claim beside it waits for that upload. A burst becomes ONE
        // trailing write that carries the latest state: the first write
        // goes at once, the next within the spacing waits and replaces
        // whatever was queued.
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let wait = CloudSendRules.trailingWait(lastWriteAtMs: lastBlobWriteAtMs, nowMs: nowMs) {
            pendingBlob = cloud
            pendingCaller = caller
            guard pendingWrite == nil else { return }
            pendingWrite = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, let blob = self.pendingBlob else { return }
                self.pendingWrite = nil
                self.pendingBlob = nil
                self.writeBlobNow(blob, by: self.pendingCaller + " (trailing)")
            }
            return
        }
        writeBlobNow(cloud, by: caller)
    }

    private var lastBlobWriteAtMs: Double = 0
    private var pendingBlob: [String: Any]?
    private var pendingCaller = ""
    private var pendingWrite: Task<Void, Never>?

    private func writeBlobNow(_ cloud: [String: Any], by caller: String) {
        lastBlobWriteAtMs = Date().timeIntervalSince1970 * 1000
        store.set(cloud, forKey: blobKey)
        store.synchronize()
        let bytes = (try? PropertyListSerialization.data(fromPropertyList: cloud, format: .binary, options: 0))?.count ?? -1
        let readBack = store.dictionary(forKey: blobKey)?.count ?? -1
        Logger.library.notice("KVS write key=\(self.blobKey, privacy: .public) entries=\(cloud.count) bytes=\(bytes) readBack=\(readBack) by=\(caller, privacy: .public)")
    }
    /// The EXISTING progress channel now also carries the
    /// classes that have no server behind them. Catalog works and local
    /// sideloads keep their position in the very same `localPosition` store,
    /// and the user's goal for these rounds is "identical state on all
    /// devices". A second channel for the same question would be exactly the
    /// second version we are abolishing everywhere else.
    ///
    /// Server-owned ids (ABS books) stay out: they travel with the server
    /// sync, which owns their truth.
    ///
    /// **Edge, deliberately not filtered:** a `local:` sideload only exists
    /// on the device that holds the file. Its POSITION still travels. That
    /// is harmless and right: device B shows the book once the file is there,
    /// and then the position is already correct.
    /// The ONE answer to "does this item's stand live in the pot": feeds,
    /// server podcasts, sideloads and every catalogue prefix. The start
    /// pull before playback asks it too, so a catalogue book on the other
    /// device starts at the pot's stand and not at the mark of the last
    /// full reconcile. A new catalogue prefix inherits the way.
    nonisolated static let potItemPrefixes = ["rss:", "abspod:", "local:"] + FreeCatalog.allPrefixes

    nonisolated static func potCarries(_ itemId: String) -> Bool {
        potItemPrefixes.contains(where: { itemId.hasPrefix($0) })
    }

    private let podcastPrefixes = PodcastCloudSync.potItemPrefixes.map { "localPosition.\($0)" }
    private let keyPrefix = "localPosition."

    private init() {}

    /// Guard against double observer registration (start() can run again when
    /// the library view is recreated, e.g. logout→login). A second observer
    /// would double every reconcile on external iCloud changes.
    private var didStart = false
    /// How many times the observer was actually registered. Must never exceed
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

    /// The reason goes through the ONE watch. Every observer of this
    /// notification asks WHY, none re-implements the comparison.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            // A foreign change is taken in, never answered with a write:
            // while this device plays, its local position is always newer
            // than the pot, so answering every foreign change (the other
            // device's claim beats among them) wrote the whole pot back
            // each time, and that write was the next foreign change over
            // there. Sending has its own occasions.
            reconcile(pushing: false)
        }
    }

    /// Merge local podcast positions and the iCloud blob (newest-wins) and bring
    /// both sides to the shared state.
    /// `pushing: false` takes the pot in and writes nothing back; the
    /// explicit callers (start, foreground, background, import, refresh)
    /// keep pushing.
    func reconcile(pushing: Bool = true, caller: String = #function) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let defaults = UserDefaults.standard

        // Collect local positions.
        var local: [String: [Double]] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard podcastPrefixes.contains(where: { key.hasPrefix($0) }),
                  let arr = Self.coerce(value), arr.count >= 2 else { continue }
            local[String(key.dropFirst(keyPrefix.count))] = arr
        }

        // iCloud blob (coerce defensively. KV store returns NSNumber arrays).
        var cloud: [String: [Double]] = [:]
        if let raw = store.dictionary(forKey: blobKey) {
            for (id, value) in raw {
                if let arr = Self.coerce(value), arr.count >= 2 { cloud[id] = arr }
            }
        }

        // The travel-set cleanup (finished episodes of unsubscribed shows
        // leave the CLOUD blob; the device and the history keep theirs).
        // Only with the subscriptions LOADED: an empty store at cold start
        // would read every show as unsubscribed and clear what it must not
        // (the loading-state class).
        var droppedCount = 0
        if PodcastSubscriptions.shared.isLoaded {
            let keys = Set(PodcastSubscriptions.shared.shows.map {
                PodcastSubscriptions.feedKey($0.feedURL)
            })
            let cleanedResult = Self.cleaned(cloud: cloud,
                                             isSubscribedShow: { keys.contains($0) })
            cloud = cleanedResult.kept
            droppedCount = cleanedResult.droppedCount
        }

        let outcome = Self.merge(local: local, cloud: cloud)
        for (id, value) in outcome.toLocal {
            defaults.set(value, forKey: keyPrefix + id)    // iCloud newer → local
        }
        // What no longer travels is not written back either; otherwise
        // the very next merge would undo the cleanup from the local side.
        var toCloud = outcome.toCloud
        if PodcastSubscriptions.shared.isLoaded {
            let keys = Set(PodcastSubscriptions.shared.shows.map {
                PodcastSubscriptions.feedKey($0.feedURL)
            })
            toCloud = toCloud.filter {
                Self.travels(id: $0.key, entry: $0.value,
                             isSubscribedShow: { keys.contains($0) })
            }
        }
        if pushing, !toCloud.isEmpty || droppedCount > 0 {
            for (id, value) in toCloud { cloud[id] = value }   // local newer → iCloud
            writeBlob(cloud, by: caller)
            if droppedCount > 0 {
                Logger.library.notice("KVS cleanup: \(droppedCount) finished episodes of unsubscribed shows left the travel set")
            }
        }
        if !outcome.toLocal.isEmpty {
            // Have the UI/sections and ABS provider display re-evaluate.
            PodcastProgressStore.shared.reload()
            // Personen-Ebene: reconciled transitions land in the listen log.
            PodcastListenLog.shared.noteReconciled(guids: outcome.toLocal.keys)
        }
        // Record full-scan merges that moved anything (single-key writes
        // stay out. They would flood the ring buffer).
        if !outcome.toLocal.isEmpty || !toCloud.isEmpty {
            SyncHistoryStore.shared.append(SyncHistory.entry(
                service: .iCloud, direction: .both,
                counters: [.init(key: .positionsDown, value: outcome.toLocal.count),
                           .init(key: .positionsUp, value: toCloud.count)],
                duration: 0,
                deviceId: SyncHistoryStore.deviceId))
        } else {
            // A clean full-scan merge leaves no ring entry. Still show
            // it ran via the "last checked" stamp.
            SyncHistoryStore.shared.noteChecked(.iCloud)
        }
    }

    /// Travel membership is DERIVED, never a tombstone: an entry travels
    /// unless it is FINISHED and its show is UNSUBSCRIBED. Re-subscribing
    /// simply makes the condition false again, and the next reconcile
    /// carries the still-local position back into the travel set; nothing
    /// to migrate, nothing that could shadow a comeback.
    ///
    /// Only rss episodes have an unsubscribe concept; server shows
    /// (abspod), catalog works and sideloads always travel. "Finished" is
    /// the ONE derived rule (`ProgressMark.isPlayed`); without a stored
    /// duration or sentinel the doubt keeps the entry aboard. Membership is
    /// judged on the SHOW, never on episode presence in the feed: a rotated-
    /// out episode of a subscribed show must not read as unsubscribed.
    nonisolated static func travels(id: String, entry: [Double],
                                    isSubscribedShow: (String) -> Bool) -> Bool {
        guard id.hasPrefix("rss:") else { return true }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty else { return true }
        if isSubscribedShow(String(parts[1])) { return true }
        return !ProgressMark.isPlayed(stored: entry, currentDuration: 0)
    }

    /// The cleanup over the CLOUD blob only. Local positions and the
    /// listen log are the device's own and are never touched here:
    /// positions leave the travel pot, never the device, never the history.
    nonisolated static func cleaned(cloud: [String: [Double]],
                                    isSubscribedShow: (String) -> Bool)
        -> (kept: [String: [Double]], droppedCount: Int) {
        var kept: [String: [Double]] = [:]
        var dropped = 0
        for (id, entry) in cloud {
            if travels(id: id, entry: entry, isSubscribedShow: isSubscribedShow) {
                kept[id] = entry
            } else {
                dropped += 1
            }
        }
        return (kept, dropped)
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
            // two-value marks with a fresh timestamp. Without this it would
            // wipe the reference point on every reconcile, silently.
            // The FORM travels exactly like the duration: the winner brings its
            // own if it has one, otherwise the other side's survives. Without
            // passing it the merge would rebuild the entry from the LOSING
            // side and the form would never leave this device. Measured, not
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

    /// Targeted single-episode merge. For the frequent per-write callers
    /// (mark played/unplayed, position saves). The full `reconcile()` enumerates
    /// the ENTIRE UserDefaults per call, which is far too expensive to run per
    /// episode (mark-all on a 200-episode show = 200 full scans).
    /// `pushing: false` only adopts a newer cloud entry (the play start
    /// asks for the freshest stand and writes nothing: a play is not a
    /// change of state, and the stand travels in the claim). `caller`
    /// names the writer in the pot's log line.
    func reconcile(changedId id: String, pushing: Bool = true, caller: String = #function) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard Self.potCarries(id) else { return }
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
            guard pushing else { break }
            // EVERY write path runs through the travel rule, or this one
            // would put a cleaned entry straight back into the pot and the
            // next full reconcile would remove it again (blob churn). With
            // the subscriptions not loaded the doubt travels, like before.
            if PodcastSubscriptions.shared.isLoaded {
                let keys = Set(PodcastSubscriptions.shared.shows.map {
                    PodcastSubscriptions.feedKey($0.feedURL)
                })
                guard Self.travels(id: id, entry: value,
                                   isSubscribedShow: { keys.contains($0) }) else { break }
            }
            cloud[id] = value
            writeBlob(cloud, by: caller)
        case .pushTombstone:
            // Local delete (mark unplayed) wins only with a fresh timestamp we
            // don't have. Write an explicit zero so other devices follow.
            cloud[id] = [0.0, Date().timeIntervalSince1970 * 1000]
            writeBlob(cloud, by: caller)
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

/// When the playing device SENDS its podcast state to the pot. Pure, so
/// the budget is testable: during playback without a change of phase the
/// pot is written at most once a minute. Measured before this rule: four
/// whole-pot writes of 325 KB in 25 seconds, one per foreign change, which
/// is the class the key-value store throttles.
nonisolated enum CloudSendRules {
    /// The cadence while playing, in seconds. The rest is events.
    static let cadenceSeconds: Double = 60

    /// A deliberate occasion (pause, stop, seek, a change of phase,
    /// import, adoption) always sends; the tick only when the cadence is
    /// due.
    static func shouldSend(deliberate: Bool, lastSentAtMs: Double, nowMs: Double) -> Bool {
        deliberate || nowMs - lastSentAtMs >= cadenceSeconds * 1000
    }

    /// The least spacing between two whole-pot writes, in seconds. A burst
    /// of writers within it becomes one trailing write with the latest
    /// state. Measured: four pots in six seconds, one per writer.
    static let minSpacingSeconds: Double = 5

    /// How long a write has to wait, or nil to write now.
    static func trailingWait(lastWriteAtMs: Double, nowMs: Double) -> Double? {
        let since = (nowMs - lastWriteAtMs) / 1000
        return since >= minSpacingSeconds ? nil : minSpacingSeconds - since
    }
}
