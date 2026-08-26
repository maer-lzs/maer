// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "Who is playing what, since when". ONE KVS key, latest writer wins.
/// Play on device B's standby pointer is a TAKEOVER: B claims, A notices the
/// foreign claim and pauses itself. No remote-control channel, no locks.
/// Play is never refused; the claim only tells the OTHER side to stand down.
nonisolated struct PlaybackClaim: Equatable {
    var deviceId: String
    var itemId: String
    /// Claim/refresh event time in ms since 1970. Refreshed while playing;
    /// a claim that stops growing is a device that stopped playing.
    var t: Double
    /// An ACTIVE withdrawal (pause wrote it): the hint line dies in
    /// KVS-delivery seconds instead of the 90-s ageing, which stays the
    /// fallback for crash/dead-zone/app-kill. A release is a normal write.
    /// Any later real claim simply outwrites it (no delete race in which a
    /// pausing device could tear down the takeover claim of another).
    var released: Bool = false

    var plist: [String: Any] {
        var out: [String: Any] = ["device": deviceId, "item": itemId, "t": t]
        if released { out["r"] = true }
        return out
    }

    static func from(plist: Any?) -> PlaybackClaim? {
        guard let dict = plist as? [String: Any],
              let device = dict["device"] as? String,
              let item = dict["item"] as? String,
              let t = (dict["t"] as? NSNumber)?.doubleValue else { return nil }
        return PlaybackClaim(deviceId: device, itemId: item, t: t,
                             released: dict["r"] as? Bool ?? false)
    }
}

nonisolated enum PlaybackClaimRules {
    /// A claim younger than this counts as "fresh and growing" (refresh runs
    /// on the 30-s sync tick, so this tolerates two missed ticks). Also the
    /// hint-line threshold. The order's ~1–2 minutes.
    static let freshSeconds: Double = 90

    static func isFresh(_ claim: PlaybackClaim, nowMs: Double) -> Bool {
        nowMs - claim.t < freshSeconds * 1000
    }

    /// The self-pause question on the PLAYING device: a foreign, fresh claim
    /// on the very item this device is playing. Freshness guards against a
    /// stale claim from a previous session. While playing, this device
    /// refreshes its own claim, so any foreign claim it sees was written
    /// AFTER its own (single key, latest writer wins).
    static func shouldPause(claim: PlaybackClaim?, ownDeviceId: String,
                            playingItemId: String?, nowMs: Double) -> Bool {
        guard let claim, let playingItemId, !claim.released else { return false }
        return claim.deviceId != ownDeviceId
            && claim.itemId == playingItemId
            && isFresh(claim, nowMs: nowMs)
    }

    /// The hint-line question on the STANDBY device: someone else is playing
    /// the pointed-at item right now.
    static func showsHint(claim: PlaybackClaim?, ownDeviceId: String,
                          standbyItemId: String?, nowMs: Double) -> Bool {
        guard let claim, let standbyItemId, !claim.released else { return false }
        return claim.deviceId != ownDeviceId
            && claim.itemId == standbyItemId
            && isFresh(claim, nowMs: nowMs)
    }
}
