// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// The runner of the playback claim (see `PlaybackClaim`): it writes the
/// own claim, reads every device's, and asks the ONE rule which foreign
/// claim counts. The transport is a `ClaimCarrier`; the key-value store
/// is the first, with the ONE iCloud switch and the ONE `CloudQuotaWatch`
/// for the change reason. Best-effort by design: there is deliberately
/// no channel that can refuse a play.
@MainActor
final class PlaybackClaimSync: ObservableObject {
    static let shared = PlaybackClaimSync()

    /// How long a device's key may sit unrefreshed before another device
    /// removes it: an orphan of a device that is gone.
    static let orphanSeconds: Double = 7 * 86_400

    /// A short, stable name for one object instance, for the log lines that
    /// have to say whether two sites talk about the same view model. The
    /// address is the tag; it is never dereferenced.
    nonisolated static func instanceTag(_ object: AnyObject) -> String {
        let address = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        return String(address, radix: 16).suffix(6).description
    }

    /// The latest known claim. Published so the standby hint line re-renders
    /// when it changes.
    @Published private(set) var current: PlaybackClaim?

    /// Set by the coordinator: called (on main) when a foreign claim arrives.
    var onForeignClaim: ((PlaybackClaim) -> Void)?

    /// The claim THIS device wrote last, and who wrote it. `current` is
    /// overwritten by a foreign claim before the hook fires, so the own
    /// side of the takeover has to be remembered separately. Cleared by
    /// the own release.
    private(set) var lastOwnClaim: PlaybackClaim?
    private(set) weak var lastWriter: AnyObject?

    private let carrier: any ClaimCarrier
    private let deviceId: () -> String
    private let deviceName: () -> String
    private let now: () -> Double
    private var didStart = false

    init(carrier: any ClaimCarrier = ClaimCarriers.make(),
         deviceId: @escaping () -> String = { SyncHistoryStore.deviceId },
         deviceName: @escaping () -> String = { DeviceIdentity.name },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.carrier = carrier
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.now = now
    }

    #if DEBUG
    /// Same rule as the choice family: the unit-test HOST and the harness
    /// must not write the simulator's real KVS (test-poisons-real-store
    /// class). Injected test instances stay fully live.
    private var sharedMustStaySilent: Bool {
        self === Self.shared
            && (UITestSeed.isHarness
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
        Logger.player.notice("CLAIM carrier=\(self.carrier.name, privacy: .public)")
        carrier.start { [weak self] in self?.poll() }
        poll()
    }

    /// Publishes/refreshes this device's claim. Called on play start and on
    /// every 30-s sync tick while playing. A claim that stops growing IS the
    /// "stopped playing" signal, so no release marker is needed.
    func claim(itemId: String, from writer: AnyObject? = nil,
               position: Double? = nil, duration: Double? = nil, title: String? = nil,
               playAt: Double? = nil) {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let claim = PlaybackClaim(deviceId: deviceId(), itemId: itemId, t: now(),
                                  position: position, duration: duration, title: title,
                                  playAt: playAt, deviceName: deviceName())
        // The write is the witness of the takeover chain: the other
        // device's log names the same item, or the chain broke here. The
        // writer's instance tag pairs with the one the coordinator's seen
        // line names, so the log says whether the view model that claims
        // is the one the coordinator holds.
        let tag = writer.map { Self.instanceTag($0) } ?? "-"
        if current?.itemId != itemId || current?.deviceId != claim.deviceId {
            Logger.player.notice("CLAIM write item=\(itemId, privacy: .private(mask: .hash)) vm=\(tag, privacy: .public)")
        } else {
            Logger.player.notice("CLAIM refresh item=\(itemId, privacy: .private(mask: .hash)) vm=\(tag, privacy: .public)")
        }
        // The writer is the witness that THIS device plays: a claim is
        // only written while playing. A takeover therefore pauses the
        // writer, whatever the coordinator happens to hold at that moment.
        // Measured: a long-running process answered every foreign claim
        // with "not playing" while its view model kept writing claims.
        lastOwnClaim = claim
        lastWriter = writer
        current = claim
        carrier.write(claim)
    }

    /// Active withdrawal on pause: the hint on the other device
    /// dies in delivery seconds instead of the 90-s ageing (which stays the
    /// fallback for crash/dead-zone/app-kill). Only the OWN key is written;
    /// another device's claim lives in its own key and is never touched.
    func release(itemId: String, position: Double? = nil, duration: Double? = nil) {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        lastOwnClaim = nil
        lastWriter = nil
        // The release carries the final stand: the taking-over device
        // catches up to it when it arrives after playback started there.
        let claim = PlaybackClaim(deviceId: deviceId(), itemId: itemId,
                                  t: now(), released: true,
                                  position: position, duration: duration)
        current = claim
        carrier.write(claim)
    }

    /// Every claim the carrier holds: one per device, plus what the
    /// builds before that wrote. Orphans of devices that are gone are
    /// removed on the way.
    func allClaims() -> [PlaybackClaim] {
        let nowMs = now()
        var claims: [PlaybackClaim] = []
        for claim in carrier.claims() {
            if claim.deviceId != deviceId(), nowMs - claim.t > Self.orphanSeconds * 1000 {
                carrier.remove(deviceId: claim.deviceId)
                continue
            }
            claims.append(claim)
        }
        return claims
    }

    /// Re-reads every claim and fires the hook for the dominant foreign one.
    /// The hook decides (via the pure rules) whether the running playback
    /// stands down.
    func poll() {
        if sharedMustStaySilent { return }
        guard AppStorageKeys.podcastICloudSyncEnabled else { return }
        let foreign = PlaybackClaimRules.dominantForeign(
            claims: allClaims(), ownDeviceId: deviceId(), nowMs: now())
        if let foreign {
            if foreign != current { current = foreign }
            onForeignClaim?(foreign)
        } else if current?.deviceId != deviceId() {
            current = nil
        }
    }
}
