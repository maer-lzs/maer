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
    /// When a person last pressed play on the claiming device, in ms. It
    /// rides on EVERY write, heartbeats included: the key-value store
    /// delivers only the latest value of a key, so a flag on the play
    /// write alone was overwritten by the next heartbeat before it
    /// arrived, and the other device never saw a play (measured: both
    /// devices kept playing). Only a play newer than the receiver's own
    /// start may stop it; heartbeats of the older player carry the older
    /// play and stop nobody. Absent on the wire (a build before this
    /// field): the write time counts as the play, so an older device
    /// still takes over.
    var playAt: Double?
    /// The claiming device by the name the person gave it, for the hint
    /// line on the other device ("Playing on iPad"). Optional on the wire.
    var deviceName: String?

    /// The play this claim stands for.
    var playTime: Double { playAt ?? t }

    var plist: [String: Any] {
        var out: [String: Any] = ["device": deviceId, "item": itemId, "t": t]
        if released { out["r"] = true }
        if let position { out["pos"] = position }
        if let duration { out["dur"] = duration }
        if let title { out["title"] = title }
        if let playAt { out["play"] = playAt }
        if let deviceName { out["name"] = deviceName }
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
                             playAt: (dict["play"] as? NSNumber)?.doubleValue,
                             deviceName: dict["name"] as? String)
    }
}

nonisolated enum PlaybackClaimRules {
    /// A claim younger than this counts as "fresh and growing" (refresh runs
    /// on the 30-s sync tick, so this tolerates two missed ticks). Also the
    /// hint-line threshold. The order's ~1–2 minutes.
    static let freshSeconds: Double = 90

    /// How long a claimed position counts as a usable start for the
    /// taking-over device. Longer than freshness: a release carries the
    /// final stand, and the takeover may come minutes later.
    static let positionValidSeconds: Double = 600

    static func isFresh(_ claim: PlaybackClaim, nowMs: Double) -> Bool {
        nowMs - claim.t < freshSeconds * 1000
    }

    /// Whether the heartbeat is due, or an event forces a write now. The
    /// beat's length is the CARRIER's (`ClaimCarrier.heartbeatSeconds`):
    /// the key-value store throttles frequent writers, the service does
    /// not, and a number that belongs to one way must not stand here for
    /// all of them.
    static func shouldRefreshClaim(lastClaimAtMs: Double, nowMs: Double,
                                   forced: Bool, heartbeatSeconds: Double) -> Bool {
        forced || nowMs - lastClaimAtMs >= heartbeatSeconds * 1000
    }

    /// The stand a pause's release carries: the position of a piece that
    /// was playing; none on a device that only held the item, whose
    /// position no other device may start from.
    static func releasePosition(wasPlaying: Bool, currentTime: Double) -> Double? {
        wasPlaying ? currentTime : nil
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

    /// What the play button of the mini player does while it shows a
    /// foreign claim: it opens THAT episode when the other device plays
    /// something else than this bar holds; otherwise it toggles the bar's
    /// own session.
    enum MiniPlayAction: Equatable {
        case toggle
        case openClaim(String)
    }

    static func miniPlayAction(claim: PlaybackClaim?, ownDeviceId: String, ownItemId: String?,
                               isPlaying: Bool, nowMs: Double) -> MiniPlayAction {
        guard !isPlaying,
              let foreign = hintClaim(claim: claim, ownDeviceId: ownDeviceId, nowMs: nowMs),
              foreign.itemId != ownItemId else { return .toggle }
        return .openClaim(foreign.itemId)
    }

    /// The TWO lines of the mini player while another device plays and this
    /// one stands by: the hint replaces the standby title instead of sitting
    /// under it (the bar showed "97. Top Ten Mistresses" over "Playing on
    /// iPad: Eurotrash", two things at once). The title
    /// line carries what plays there, the second line names the device;
    /// when the other device plays the very item this bar holds, or names
    /// none, the bar's own title stays and only the device line changes.
    /// The standby returns by itself once the claim is released or ages.
    static func hintLines(claim: PlaybackClaim, ownTitle: String, ownItemId: String?)
        -> (title: String, subtitle: String) {
        let device = claim.deviceName ?? String(localized: "another device")
        let subtitle = String(localized: "Playing on \(device)")
        if let title = claim.title, !title.isEmpty, claim.itemId != ownItemId {
            return (title, subtitle)
        }
        return (ownTitle, subtitle)
    }

    /// The self-pause question on the PLAYING device: a foreign, fresh claim
    /// on the very item this device is playing. Freshness guards against a
    /// stale claim from a previous session. While playing, this device
    /// refreshes its own claim, so any foreign claim it sees was written
    /// AFTER its own (single key, latest writer wins).
    static func shouldPause(claim: PlaybackClaim?, ownDeviceId: String,
                            playingItemId: String?, nowMs: Double,
                            ownStartedAtMs: Double = 0) -> Bool {
        guard let claim, playingItemId != nil, !claim.released else { return false }
        // The newest PLAY wins, on both sides alike: a foreign claim stops
        // this device only when a person pressed play there AFTER this
        // playback started. Measured on the switch back: the other
        // device's heartbeat, older than this play but fresh, stopped the
        // device that had just taken over. WHATEVER plays there: one
        // account is one listener, two devices at once is what switching
        // iCloud sync off is for.
        return claim.deviceId != ownDeviceId
            && isFresh(claim, nowMs: nowMs)
            && claim.playTime > ownStartedAtMs
    }

    /// Among every device's claim, the foreign one that counts: fresh, not
    /// released first, and among those the newest play. Each device keeps
    /// its own key, so nobody's play is overwritten; the reader decides.
    static func dominantForeign(claims: [PlaybackClaim], ownDeviceId: String,
                                nowMs: Double) -> PlaybackClaim? {
        let foreign = claims.filter { $0.deviceId != ownDeviceId }
        let live = foreign.filter { !$0.released && isFresh($0, nowMs: nowMs) }
        if let best = live.max(by: { ($0.playTime, $0.t) < ($1.playTime, $1.t) }) { return best }
        // No live claim: the newest release still carries a final stand
        // for the catch-up, and says that the other device stopped.
        return foreign.max(by: { $0.t < $1.t })
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

    // MARK: - The player's tick

    /// The player's tick while a player exists, in seconds. Measured on the
    /// probe: a silent push never reaches a
    /// locked, playing device, so the poll for a foreign claim is the
    /// promise of the takeover, and it runs every tick while playing.
    static let tickSeconds: Double = 10
    /// The server sync and the own heartbeat keep their cadence: every
    /// third tick, thirty seconds.
    static let ticksPerSync = 3

    static func syncDue(tick: Int) -> Bool {
        tick % ticksPerSync == 0
    }

    /// While playing every tick; otherwise with the sync, every third.
    static func pollDue(tick: Int, playing: Bool) -> Bool {
        playing || syncDue(tick: tick)
    }

    /// Whether something that runs every `everySeconds` is due on this
    /// tick. The cadence is the carrier's; a cadence shorter than a tick
    /// runs every tick, one that is not a multiple rounds down.
    static func due(tick: Int, everySeconds: Double, tickSeconds: Double = tickSeconds) -> Bool {
        let ticks = max(1, Int(everySeconds / tickSeconds))
        return tick % ticks == 0
    }
}
