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
    /// Where the playing device stands, refreshed with the heartbeat and
    /// on every jump, and written once more with the release as the final
    /// stand. The taking-over device starts HERE instead of at the pot's
    /// last save, and catches up when the final stand arrives later.
    /// Optional on the wire: a claim from an older build carries none.
    var position: Double?
    var duration: Double?
    /// What plays, for the hint on the other device. The hint used to
    /// need the standby item to match, which no catalogue or radio item
    /// on the other device ever did.
    var title: String?
    /// Whether a person pressed play for this claim, or the heartbeat
    /// refreshed it. Only a play may stop the other device: heartbeats of
    /// both sides cross in the delivery seconds after a switch back, and a
    /// beat that could pause would stop BOTH devices. Absent on the wire
    /// (a build before this field) counts as a play, so an older device
    /// still takes over.
    var userPlay: Bool = true

    var plist: [String: Any] {
        var out: [String: Any] = ["device": deviceId, "item": itemId, "t": t]
        if released { out["r"] = true }
        if let position { out["pos"] = position }
        if let duration { out["dur"] = duration }
        if let title { out["title"] = title }
        if !userPlay { out["beat"] = true }
        return out
    }

    static func from(plist: Any?) -> PlaybackClaim? {
        guard let dict = plist as? [String: Any],
              let device = dict["device"] as? String,
              let item = dict["item"] as? String,
              let t = (dict["t"] as? NSNumber)?.doubleValue else { return nil }
        return PlaybackClaim(deviceId: device, itemId: item, t: t,
                             released: dict["r"] as? Bool ?? false,
                             position: (dict["pos"] as? NSNumber)?.doubleValue,
                             duration: (dict["dur"] as? NSNumber)?.doubleValue,
                             title: dict["title"] as? String,
                             userPlay: !(dict["beat"] as? Bool ?? false))
    }
}

nonisolated enum PlaybackClaimRules {
    /// A claim younger than this counts as "fresh and growing" (refresh runs
    /// on the 30-s sync tick, so this tolerates two missed ticks). Also the
    /// hint-line threshold. The order's ~1–2 minutes.
    static let freshSeconds: Double = 90

    /// How often the playing device refreshes its claim. Not more often:
    /// delivery dominates, and the key-value store throttles frequent
    /// writers. Measured before it is fixed for good: whether the store
    /// passes every beat or coalesces them decides this number.
    static let heartbeatSeconds: Double = 10

    /// How long a claimed position counts as a usable start for the
    /// taking-over device. Longer than freshness: a release carries the
    /// final stand, and the takeover may come minutes later.
    static let positionValidSeconds: Double = 600

    static func isFresh(_ claim: PlaybackClaim, nowMs: Double) -> Bool {
        nowMs - claim.t < freshSeconds * 1000
    }

    /// Whether the heartbeat is due, or an event forces a write now.
    static func shouldRefreshClaim(lastClaimAtMs: Double, nowMs: Double,
                                   forced: Bool) -> Bool {
        forced || nowMs - lastClaimAtMs >= heartbeatSeconds * 1000
    }

    /// The position the taking-over device starts at: the other device's
    /// claim on the same item, with a position, not older than the
    /// validity window. Released or not, both carry the freshest stand
    /// that device knew.
    static func takeoverPosition(claim: PlaybackClaim?, itemId: String,
                                 ownDeviceId: String, nowMs: Double) -> Double? {
        guard let claim, claim.deviceId != ownDeviceId, claim.itemId == itemId,
              let position = claim.position,
              nowMs - claim.t < positionValidSeconds * 1000 else { return nil }
        return position
    }

    /// The catch-up on the taking-over device once the other side's final
    /// stand arrives: only a released foreign claim on the playing item,
    /// written after this PLAYBACK started (the start, never the last
    /// heartbeat, which moves every ten seconds and would outrun every
    /// release), and only FORWARD. While both devices overlapped, the
    /// other side's final stand lies behind this one; jumping back would
    /// play the overlap a second time.
    static func catchUpPosition(claim: PlaybackClaim?, playingItemId: String?,
                                ownDeviceId: String, startedAtMs: Double,
                                currentTime: Double, toleranceSeconds: Double = 3) -> Double? {
        guard let claim, let playingItemId, claim.released,
              claim.deviceId != ownDeviceId, claim.itemId == playingItemId,
              claim.t > startedAtMs, let position = claim.position,
              position - currentTime > toleranceSeconds else { return nil }
        return position
    }

    /// The hint on a device that does not play: the foreign fresh claim,
    /// whatever it names. The old form needed the standby item to match
    /// the claim, and no catalogue or radio item on the other device ever
    /// did, so those sources never showed the hint.
    static func hintClaim(claim: PlaybackClaim?, ownDeviceId: String,
                          nowMs: Double) -> PlaybackClaim? {
        guard let claim, !claim.released, claim.deviceId != ownDeviceId,
              isFresh(claim, nowMs: nowMs) else { return nil }
        return claim
    }

    /// The self-pause question on the PLAYING device: a foreign, fresh claim
    /// on the very item this device is playing. Freshness guards against a
    /// stale claim from a previous session. While playing, this device
    /// refreshes its own claim, so any foreign claim it sees was written
    /// AFTER its own (single key, latest writer wins).
    static func shouldPause(claim: PlaybackClaim?, ownDeviceId: String,
                            playingItemId: String?, nowMs: Double,
                            ownStartedAtMs: Double = 0) -> Bool {
        guard let claim, let playingItemId, !claim.released else { return false }
        // The newest PLAY wins, on both sides alike: a foreign claim stops
        // this device only when a person pressed play there AFTER this
        // playback started. Measured on the switch back: the other
        // device's heartbeat, older than this play but fresh, stopped the
        // device that had just taken over.
        return claim.deviceId != ownDeviceId
            && claim.itemId == playingItemId
            && isFresh(claim, nowMs: nowMs)
            && claim.userPlay
            && claim.t > ownStartedAtMs
    }

    /// What THIS device is playing, for the self-pause question. The
    /// coordinator's answer first; when it holds nothing that says it
    /// plays, the own fresh, unreleased claim is the second witness, since
    /// a claim is only ever written while playing. Measured class: a
    /// long-running process answered every foreign claim with "not
    /// playing" while its view model kept refreshing the claim.
    static func playingItem(held: String?, ownClaim: PlaybackClaim?,
                            ownDeviceId: String, nowMs: Double) -> String? {
        if let held { return held }
        guard let ownClaim, ownClaim.deviceId == ownDeviceId, !ownClaim.released,
              isFresh(ownClaim, nowMs: nowMs) else { return nil }
        return ownClaim.itemId
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
