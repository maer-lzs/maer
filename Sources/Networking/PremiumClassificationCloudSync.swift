// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// P2 (2): the CLASSIFICATION truths across a person's own devices — the
/// half of premium parity that gpodder cannot carry.
///
/// Two device-local `UserDefaults` truths made the same subscription look
/// different on two devices: the **hand markings** (`premiumMarkedFeeds` —
/// "this feed IS premium, whatever its URL looks like") and the **block
/// signals** (`blockedFeedKeys`). Both are decisions of the person, not
/// properties of a device, so they belong on the iCloud channel that
/// already carries progress and playlists — same switch, same store, same
/// 1 MB budget (which is why there is only one switch at all).
///
/// The merge is deliberately a UNION with tombstones-free semantics: these
/// are small sets of explicit user statements, and a lost marking silently
/// downgrades a premium feed on the other device (field-class rule:
/// knowledge only one side has must not die). Un-marking is therefore an
/// explicit removal that travels as its own statement.
@MainActor
final class PremiumClassificationCloudSync {
    static let shared = PremiumClassificationCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private let markedKey = "premiumMarkedFeeds"
    private let blockedKey = "blockedFeedKeys"
    /// What this device has explicitly REMOVED — without it a union would
    /// resurrect every un-marking from the other device's copy.
    private let removedMarkedKey = "premiumMarkedFeedsRemoved"
    private let removedBlockedKey = "blockedFeedKeysRemoved"
    private var didStart = false
    private init() {}

    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
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

    func reconcile() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        merge(local: AppStorageKeys.premiumMarkedFeeds, cloud: markedKey,
              removed: removedMarkedKey)
        merge(local: AppStorageKeys.blockedFeedKeys, cloud: blockedKey,
              removed: removedBlockedKey)
    }

    /// Record an explicit removal so the union cannot resurrect it. Called by
    /// the setters; without iCloud this is a no-op beyond the local write.
    func noteRemoval(_ feedKey: String, from local: String) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let cloudKey = local == AppStorageKeys.premiumMarkedFeeds ? removedMarkedKey : removedBlockedKey
        var removed = Set(store.array(forKey: cloudKey) as? [String] ?? [])
        removed.insert(feedKey)
        store.set(Array(removed).sorted(), forKey: cloudKey)
    }

    /// Record that this key is set again — it leaves the removal list, so a
    /// re-marking is not undone by its own tombstone.
    func noteAddition(_ feedKey: String, from local: String) {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let cloudKey = local == AppStorageKeys.premiumMarkedFeeds ? removedMarkedKey : removedBlockedKey
        var removed = Set(store.array(forKey: cloudKey) as? [String] ?? [])
        guard removed.remove(feedKey) != nil else { return }
        store.set(Array(removed).sorted(), forKey: cloudKey)
    }

    private func merge(local localKey: String, cloud cloudKey: String, removed removedKey: String) {
        let defaults = UserDefaults.standard
        let mine = Set(defaults.stringArray(forKey: localKey) ?? [])
        let theirs = Set(store.array(forKey: cloudKey) as? [String] ?? [])
        let removed = Set(store.array(forKey: removedKey) as? [String] ?? [])
        let merged = mine.union(theirs).subtracting(removed)
        if merged != mine {
            defaults.set(Array(merged).sorted(), forKey: localKey)
            Logger.library.notice("PREMIUM classification merged \(localKey, privacy: .public): local=\(mine.count) cloud=\(theirs.count) → \(merged.count)")
        }
        if merged != theirs {
            store.set(Array(merged).sorted(), forKey: cloudKey)
        }
    }
}
