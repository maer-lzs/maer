// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Carries the listening statistics between a person's own devices, through the
/// same `NSUbiquitousKeyValueStore` and the same ONE iCloud switch as podcast
/// progress and playlists — two switches would suggest an independence that the
/// shared 1 MB budget does not grant.
///
/// One key per device (`listeningStats.<deviceId>`): this device writes only its
/// own, reads all, and sums on read. No device ever touches a foreign value, so
/// there is no write race to lose time to.
@MainActor
final class ListeningStatsCloudSync {
    static let shared = ListeningStatsCloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private init() {}

    private var didStart = false
    /// Must never exceed 1 — a second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    func start() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { publish(); return }
        didStart = true
        observerRegistrations += 1
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store)
        store.synchronize()
        publish()
    }

    /// Only the REASON crosses the actor boundary, not the notification: a
    /// `Notification` is not `Sendable`, and the code is all this needs.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in self.handle(reason: reason) }
    }

    private func handle(reason: Int?) {
        // beff8bd: the reason goes through the ONE watch — the check used to
        // live here, which made its coverage narrower than its purpose (this
        // service bails out when the iCloud switch is off, while the three
        // other cloud paths never looked at the reason at all).
        CloudQuotaWatch.note(reason: reason)
        ListeningStatsStore.shared.cloudChanged()
    }

    /// This device's pot, as it stands right now. Called after a flush, so the
    /// published copy never lags the file by more than one flush interval.
    func publish() {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let own = ListeningStatsSync.publishable(ListeningStatsStore.shared.ownData)
        guard let encoded = try? JSONEncoder().encode(own) else { return }
        store.set(encoded, forKey: ListeningStatsSync.key(forDeviceId: SyncHistoryStore.deviceId))
    }

    /// Every OTHER device's pot. The own key is skipped by the merge rule, not
    /// here — the rule is the one place that knows why (the local file is the
    /// fresher copy of the same numbers).
    func foreignPots() -> [String: ListeningStatsData] {
        guard AppStorageKeys.podcastICloudSyncEnabled else { return [:] }
        var out: [String: ListeningStatsData] = [:]
        for (key, value) in store.dictionaryRepresentation {
            guard let deviceId = ListeningStatsSync.deviceId(fromKey: key),
                  let data = value as? Data,
                  let decoded = try? JSONDecoder().decode(ListeningStatsData.self, from: data)
            else { continue }
            out[deviceId] = decoded
        }
        return out
    }
}
