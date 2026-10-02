// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The transport behind the playback claim. A carrier stores and delivers
/// claims, nothing more: who pauses, who shows the hint, which foreign
/// claim counts, all of that stays the ONE rule in `PlaybackClaimRules`
/// and its runner `PlaybackClaimSync`. The key-value store is the first
/// carrier; the Mär sync service, an Audiobookshelf session or a direct
/// connection hang in here later without touching the rule.
@MainActor
protocol ClaimCarrier: AnyObject {
    /// A short name for the log line that says which carrier runs.
    var name: String { get }
    /// Writes this device's claim; a release is a claim with `released`.
    /// Only the own claim is ever written, another device's is untouchable.
    func write(_ claim: PlaybackClaim)
    /// Every claim the carrier holds: one per device, plus what older
    /// builds wrote.
    func claims() -> [PlaybackClaim]
    /// Drops the claim of a device that is gone.
    func remove(deviceId: String)
    /// Starts delivery. `onChange` fires on main whenever a foreign write
    /// arrived; the runner re-reads and decides.
    func start(onChange: @escaping @MainActor () -> Void)
    /// The runner took another carrier: from now on this one writes,
    /// removes and delivers nothing.
    func stop()
    /// The least time between two writes of the own claim while playing,
    /// in seconds. A number of the WAY, not of the rule: the key-value
    /// store throttles frequent writers, another carrier may not, and the
    /// runner asks rather than assuming.
    var heartbeatSeconds: Double { get }
    /// The way's name for the measuring points. Asked of the carrier, so the
    /// runner never names the way itself.
    var signpostCarrier: PerfSignpost.Carrier { get }
}

extension ClaimCarrier {
    /// A carrier that names no way (a witness's stand-in) measures as local.
    var signpostCarrier: PerfSignpost.Carrier { .local }
}

/// Which carrier the claim runs on: the Mär sync service when the person
/// set one up, the key-value store otherwise. The same question the pot
/// asks, answered the same way.
@MainActor
enum ClaimCarriers {
    static func make(access: MaerSyncAccess? = MaerSyncAccess.stored()) -> any ClaimCarrier {
        if access != nil { return MaerSyncClaimCarrier(session: MaerSyncCarriers.session) }
        return KeyValueClaimCarrier()
    }
}

/// The key-value store as carrier: today's one path, best-effort by
/// design. The takeover rides the external-change notification (near
/// real time between devices of one Apple ID); the 30-s sync tick of the
/// runner is the polling fallback.
@MainActor
final class KeyValueClaimCarrier: ClaimCarrier {
    /// The key builds before 26 wrote: ONE key for every device.
    /// Measured with two devices beating every ten seconds: the store keeps
    /// one value per key and the last writer wins, so one device's play
    /// was thrown away by the other's heartbeat before it was delivered,
    /// and both kept playing. Still READ, so a device on an older build
    /// is seen; never written again.
    nonisolated static let claimKey = "playbackClaim"
    nonisolated static let claimKeyPrefix = "playbackClaim."

    /// The key one device writes, and only that device.
    nonisolated static func key(for deviceId: String) -> String { claimKeyPrefix + deviceId }

    let name = "kvs"
    /// Not more often: delivery dominates, and the key-value store
    /// throttles frequent writers. Measured before it is fixed for good:
    /// whether the store passes every beat or coalesces them decides this
    /// number. It used to stand in the rule for every way.
    let heartbeatSeconds: Double = 10
    var signpostCarrier: PerfSignpost.Carrier { .keyValue }
    private let cloud: any UserChoiceCloudStore
    private var onChange: (@MainActor () -> Void)?

    init(cloud: any UserChoiceCloudStore = CloudKeyValue.store) {
        self.cloud = cloud
    }

    func write(_ claim: PlaybackClaim) {
        guard !stopped else { return }
        cloud.set(claim.plist, forKey: Self.key(for: claim.deviceId))
        _ = cloud.synchronize()
    }

    func claims() -> [PlaybackClaim] {
        var out: [PlaybackClaim] = []
        for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(Self.claimKeyPrefix) {
            if let claim = PlaybackClaim.from(plist: value) { out.append(claim) }
        }
        if let legacy = PlaybackClaim.from(plist: cloud.dictionary(forKey: Self.claimKey)) {
            out.append(legacy)
        }
        return out
    }

    func remove(deviceId: String) {
        guard !stopped else { return }
        cloud.removeObject(forKey: Self.key(for: deviceId))
    }

    func stop() {
        stopped = true
        onChange = nil
        NotificationCenter.default.removeObserver(self)
    }
    private var stopped = false

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore)
        _ = cloud.synchronize()
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.onChange?()
        }
    }
}
