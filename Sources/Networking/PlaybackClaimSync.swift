// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// KVS side of the playback claim (see `PlaybackClaim`). Same channel
/// discipline as the other cloud services: the ONE iCloud switch, the ONE
/// `CloudQuotaWatch` for the change reason. Best-effort by design — the
/// takeover pause rides the external-change notification (near real time
/// between devices of one Apple ID) with the 30-s sync tick as the polling
/// fallback; there is deliberately no channel that can refuse a play.
@MainActor
final class PlaybackClaimSync: ObservableObject {
    static let shared = PlaybackClaimSync()

    static let claimKey = "playbackClaim"

    /// The latest known claim — published so the standby hint line re-renders
    /// when it changes.
    @Published private(set) var current: PlaybackClaim?

    /// Set by the coordinator: called (on main) when a foreign claim arrives.
    var onForeignClaim: ((PlaybackClaim) -> Void)?

    private let cloud: any UserChoiceCloudStore
    private let deviceId: () -> String
    private let now: () -> Double
    private var didStart = false

    init(cloud: any UserChoiceCloudStore = NSUbiquitousKeyValueStore.default,
         deviceId: @escaping () -> String = { SyncHistoryStore.deviceId },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.cloud = cloud
        self.deviceId = deviceId
        self.now = now
    }

    #if DEBUG
    /// Same rule as the choice family: the unit-test HOST and the harness
    /// must not write the simulator's real KVS (test-poisons-real-store
    /// class). Injected test instances stay fully live.
    private var sharedMustStaySilent: Bool {
        self === Self.shared
            && (UITestSeed.isActive
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
    #else
    private var sharedMustStaySilent: Bool { false }
    #endif

    func start() {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        guard !didStart else { poll(); return }
        didStart = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore)
        _ = cloud.synchronize()
        poll()
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.poll()
        }
    }

    /// Publishes/refreshes this device's claim. Called on play start and on
    /// every 30-s sync tick while playing — a claim that stops growing IS the
    /// "stopped playing" signal, so no release marker is needed.
    func claim(itemId: String) {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let claim = PlaybackClaim(deviceId: deviceId(), itemId: itemId, t: now())
        current = claim
        cloud.set(claim.plist, forKey: Self.claimKey)
        _ = cloud.synchronize()
    }

    /// Active withdrawal on pause: the hint on the other device
    /// dies in delivery seconds instead of the 90-s ageing (which stays the
    /// fallback for crash/dead-zone/app-kill). Only the OWN claim is
    /// released — a foreign claim in the key means another device took over,
    /// and its claim must not be touched.
    func release(itemId: String) {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let stored = PlaybackClaim.from(plist: cloud.dictionary(forKey: Self.claimKey))
        guard stored == nil || stored?.deviceId == deviceId() else { return }
        let claim = PlaybackClaim(deviceId: deviceId(), itemId: itemId,
                                  t: now(), released: true)
        current = claim
        cloud.set(claim.plist, forKey: Self.claimKey)
        _ = cloud.synchronize()
    }

    /// Re-reads the claim and fires the foreign-claim hook. The hook decides
    /// (via the pure rules) whether the running playback stands down.
    func poll() {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let claim = PlaybackClaim.from(plist: cloud.dictionary(forKey: Self.claimKey))
        if claim != current { current = claim }
        if let claim, claim.deviceId != deviceId() {
            onForeignClaim?(claim)
        }
    }
}
