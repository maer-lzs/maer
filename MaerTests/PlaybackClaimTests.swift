// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Takeover semantics: play on the standby pointer claims; the
/// playing device notices the foreign claim and stands down by itself.
struct PlaybackClaimRulesTests {

    private let now: Double = 1_000_000

    private func claim(_ device: String, _ item: String, ageSeconds: Double)
        -> PlaybackClaim {
        PlaybackClaim(deviceId: device, itemId: item, t: now - ageSeconds * 1000)
    }

    @Test func codecRoundTrip() {
        let c = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: 42)
        #expect(PlaybackClaim.from(plist: c.plist) == c)
        #expect(PlaybackClaim.from(plist: nil) == nil)
        #expect(PlaybackClaim.from(plist: ["device": "x"]) == nil)
        // Position, duration and title travel; a claim from an older build
        // without them still decodes (the literal of the old wire form).
        let full = PlaybackClaim(deviceId: "dev-a", itemId: "lva:x#3", t: 42,
                                 position: 123.5, duration: 900, title: "Track")
        #expect(PlaybackClaim.from(plist: full.plist) == full)
        let old: [String: Any] = ["device": "dev-b", "item": "rss:f:ep", "t": 7.0]
        let decoded = PlaybackClaim.from(plist: old)
        #expect(decoded?.position == nil && decoded?.title == nil)
    }

    /// The taking-over device starts where the other one stood, and
    /// catches up to the final stand that arrives after its own start.
    @Test("the claimed position is the takeover start; the release is the catch-up")
    func positionTravelsWithTheClaim() {
        let foreign = PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep",
                                    t: now - 30_000, position: 600, duration: 1800)
        #expect(PlaybackClaimRules.takeoverPosition(claim: foreign, itemId: "rss:f:ep",
                                                    ownDeviceId: "dev-a", nowMs: now) == 600)
        // Rot-Proben: own claim, other item, no position, too old.
        var own = foreign; own.deviceId = "dev-a"
        #expect(PlaybackClaimRules.takeoverPosition(claim: own, itemId: "rss:f:ep",
                                                    ownDeviceId: "dev-a", nowMs: now) == nil)
        #expect(PlaybackClaimRules.takeoverPosition(claim: foreign, itemId: "rss:f:other",
                                                    ownDeviceId: "dev-a", nowMs: now) == nil)
        var blank = foreign; blank.position = nil
        #expect(PlaybackClaimRules.takeoverPosition(claim: blank, itemId: "rss:f:ep",
                                                    ownDeviceId: "dev-a", nowMs: now) == nil)
        var old = foreign; old.t = now - 700_000
        #expect(PlaybackClaimRules.takeoverPosition(claim: old, itemId: "rss:f:ep",
                                                    ownDeviceId: "dev-a", nowMs: now) == nil)

        // Catch-up: only a RELEASED foreign claim written after this start,
        // and only FORWARD by more than the tolerance.
        let started = now - 20_000
        var released = foreign; released.released = true; released.t = now - 5_000
        released.position = 650
        // (2) The final stand lies AHEAD of this device: catch up.
        #expect(PlaybackClaimRules.catchUpPosition(claim: released, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: started,
                                                   currentTime: 610) == 650)
        // (1) The final stand lies BEHIND this device (the overlap): nothing,
        // never a jump back that plays the overlap twice.
        #expect(PlaybackClaimRules.catchUpPosition(claim: released, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: started,
                                                   currentTime: 700) == nil, "behind means no jump back")
        #expect(PlaybackClaimRules.catchUpPosition(claim: released, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: started,
                                                   currentTime: 649) == nil, "within tolerance")
        #expect(PlaybackClaimRules.catchUpPosition(claim: foreign, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: started,
                                                   currentTime: 0) == nil, "not released")
        var before = released; before.t = started - 1
        #expect(PlaybackClaimRules.catchUpPosition(claim: before, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: started,
                                                   currentTime: 0) == nil, "written before this start")
    }

    /// (3) The start the catch-up compares against is the PLAYBACK start,
    /// never the last heartbeat: B starts at T0 and beats at T0+10, T0+20;
    /// A's release carries t = T0+12 and reaches B after the second beat.
    /// Against the start it fires; against the last beat it never would,
    /// which is the measured class where the catch-up practically never ran.
    @Test("the catch-up compares against the playback start, not the last heartbeat")
    func catchUpUsesThePlaybackStart() {
        let t0 = now - 60_000
        let release = PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep", t: t0 + 12_000,
                                    released: true, position: 900)
        // Three heartbeats have passed on B; its playback started at t0.
        let lastHeartbeat = t0 + 20_000
        #expect(PlaybackClaimRules.catchUpPosition(claim: release, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: t0,
                                                   currentTime: 100) == 900)
        // Rot-Probe: the last heartbeat as the start swallows the release.
        #expect(PlaybackClaimRules.catchUpPosition(claim: release, playingItemId: "rss:f:ep",
                                                   ownDeviceId: "dev-a", startedAtMs: lastHeartbeat,
                                                   currentTime: 100) == nil)
    }

    /// The hint names the foreign claim whatever it plays: the standby of
    /// this device no longer has to match, which no catalogue or radio
    /// item ever did.
    @Test("the hint follows any foreign fresh claim, not the standby item")
    func hintFollowsTheForeignClaim() {
        let foreign = PlaybackClaim(deviceId: "dev-b", itemId: "radio:rb:x",
                                    t: now - 10_000, title: "Some Station")
        #expect(PlaybackClaimRules.hintClaim(claim: foreign, ownDeviceId: "dev-a",
                                             nowMs: now)?.title == "Some Station")
        var own = foreign; own.deviceId = "dev-a"
        #expect(PlaybackClaimRules.hintClaim(claim: own, ownDeviceId: "dev-a", nowMs: now) == nil)
        var released = foreign; released.released = true
        #expect(PlaybackClaimRules.hintClaim(claim: released, ownDeviceId: "dev-a", nowMs: now) == nil)
        var stale = foreign; stale.t = now - 200_000
        #expect(PlaybackClaimRules.hintClaim(claim: stale, ownDeviceId: "dev-a", nowMs: now) == nil)
        // The heartbeat rule: due after the beat, or forced by an event.
        #expect(PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now - 10_000, nowMs: now, forced: false))
        #expect(!PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now - 9_000, nowMs: now, forced: false))
        #expect(PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now, nowMs: now, forced: true))
    }

    /// The own claim is the second witness of "this device plays": the
    /// long-running process that answered every takeover with "not playing"
    /// while it kept writing claims is the class this pins.
    @Test("the own fresh claim says what plays when the coordinator says nothing")
    func ownClaimIsTheSecondWitness() {
        let own = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: now - 20_000)
        // The coordinator's answer wins when it has one.
        #expect(PlaybackClaimRules.playingItem(held: "other", ownClaim: own,
                                               ownDeviceId: "dev-a", nowMs: now) == "other")
        // Without it, the own fresh claim names the item.
        #expect(PlaybackClaimRules.playingItem(held: nil, ownClaim: own,
                                               ownDeviceId: "dev-a", nowMs: now) == "rss:f:ep")
        // Rot-Proben: released, stale, or foreign claims say nothing.
        var released = own; released.released = true
        #expect(PlaybackClaimRules.playingItem(held: nil, ownClaim: released,
                                               ownDeviceId: "dev-a", nowMs: now) == nil)
        let stale = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: now - 200_000)
        #expect(PlaybackClaimRules.playingItem(held: nil, ownClaim: stale,
                                               ownDeviceId: "dev-a", nowMs: now) == nil)
        #expect(PlaybackClaimRules.playingItem(held: nil, ownClaim: own,
                                               ownDeviceId: "dev-b", nowMs: now) == nil)
        #expect(PlaybackClaimRules.playingItem(held: nil, ownClaim: nil,
                                               ownDeviceId: "dev-a", nowMs: now) == nil)
        // And with that witness the takeover pauses.
        let foreign = PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep", t: now - 5_000)
        #expect(PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a",
            playingItemId: PlaybackClaimRules.playingItem(held: nil, ownClaim: own,
                                                          ownDeviceId: "dev-a", nowMs: now),
            nowMs: now))
    }

    @Test("Self-pause ONLY on a foreign, fresh claim on the playing item")
    func pauseMatrix() {
        let foreign = claim("dev-b", "item-1", ageSeconds: 5)
        #expect(PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        // The own claim never pauses anything.
        #expect(!PlaybackClaimRules.shouldPause(
            claim: claim("dev-a", "item-1", ageSeconds: 5),
            ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        // A claim on a DIFFERENT item is someone listening to something else.
        #expect(!PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: "item-2", nowMs: now))
        // A stale claim is a previous session, not a takeover.
        #expect(!PlaybackClaimRules.shouldPause(
            claim: claim("dev-b", "item-1", ageSeconds: PlaybackClaimRules.freshSeconds + 1),
            ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.shouldPause(
            claim: nil, ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: nil, nowMs: now))
    }

    @Test("Hint line: foreign fresh claim on the standby item — nothing else")
    func hintMatrix() {
        let foreign = claim("dev-b", "item-1", ageSeconds: 30)
        #expect(PlaybackClaimRules.showsHint(
            claim: foreign, ownDeviceId: "dev-a", standbyItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.showsHint(
            claim: claim("dev-a", "item-1", ageSeconds: 30),
            ownDeviceId: "dev-a", standbyItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.showsHint(
            claim: claim("dev-b", "item-1", ageSeconds: PlaybackClaimRules.freshSeconds + 1),
            ownDeviceId: "dev-a", standbyItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.showsHint(
            claim: foreign, ownDeviceId: "dev-a", standbyItemId: "item-2", nowMs: now))
    }

    @Test("A released claim neither pauses nor hints — and survives the codec")
    func releasedClaimIsInert() {
        var c = claim("dev-b", "item-1", ageSeconds: 5)
        c.released = true
        #expect(!PlaybackClaimRules.shouldPause(
            claim: c, ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.showsHint(
            claim: c, ownDeviceId: "dev-a", standbyItemId: "item-1", nowMs: now))
        #expect(PlaybackClaim.from(plist: c.plist) == c)
    }
}

@MainActor
struct PlaybackClaimSyncTests {

    @Test("Claim writes the shared key; poll fires the hook for foreign claims only")
    func claimAndPoll() {
        let cloud = UserChoiceFakeCloud()
        var clockA: Double = 1000
        let a = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-a" },
                                  now: { clockA += 1; return clockA })
        var clockB: Double = 2000
        let b = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-b" },
                                  now: { clockB += 1; return clockB })

        var aHeard: PlaybackClaim?
        a.onForeignClaim = { aHeard = $0 }
        var bHeard: PlaybackClaim?
        b.onForeignClaim = { bHeard = $0 }

        a.claim(itemId: "item-1")
        a.poll()
        #expect(aHeard == nil)          // the own claim never fires the hook
        #expect(a.current?.deviceId == "dev-a")

        // B takes over: latest writer wins the single key, A hears it.
        b.claim(itemId: "item-1")
        b.poll()
        #expect(bHeard == nil)
        a.poll()
        #expect(aHeard?.deviceId == "dev-b")
        #expect(aHeard?.itemId == "item-1")
        #expect(a.current?.deviceId == "dev-b")
    }

    /// The sync remembers the own side across the foreign overwrite: after
    /// B's claim replaced `current`, A still knows what it wrote and who
    /// wrote it, and the release forgets both.
    @Test("the own claim and its writer survive the foreign overwrite; release forgets them")
    func ownClaimSurvivesForeignOverwrite() {
        final class Writer {}
        let cloud = UserChoiceFakeCloud()
        var clock: Double = 1000
        let a = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-a" },
                                  now: { clock += 1; return clock })
        let b = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-b" },
                                  now: { clock += 1; return clock })
        let writer = Writer()
        a.claim(itemId: "item-1", from: writer)
        b.claim(itemId: "item-1")
        a.poll()
        #expect(a.current?.deviceId == "dev-b", "the foreign claim replaced current")
        #expect(a.lastOwnClaim?.itemId == "item-1")
        #expect(a.lastOwnClaim?.deviceId == "dev-a")
        #expect(a.lastWriter === writer)
        a.release(itemId: "item-1")
        #expect(a.lastOwnClaim == nil)
        #expect(a.lastWriter == nil)
    }

    @Test("Release withdraws only the OWN claim — a takeover claim is untouchable")
    func releaseGuardsForeignClaims() {
        let cloud = UserChoiceFakeCloud()
        var clockA: Double = 1000
        let a = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-a" },
                                  now: { clockA += 1; return clockA })
        var clockB: Double = 2000
        let b = PlaybackClaimSync(cloud: cloud, deviceId: { "dev-b" },
                                  now: { clockB += 1; return clockB })

        // Own claim → release marks it withdrawn.
        a.claim(itemId: "item-1")
        a.release(itemId: "item-1")
        var stored = PlaybackClaim.from(plist: cloud.storage[PlaybackClaimSync.claimKey])
        #expect(stored?.released == true && stored?.deviceId == "dev-a")

        // B takes over; A's pause must NOT tear B's claim down.
        b.claim(itemId: "item-1")
        a.release(itemId: "item-1")
        stored = PlaybackClaim.from(plist: cloud.storage[PlaybackClaimSync.claimKey])
        #expect(stored?.released == false && stored?.deviceId == "dev-b")
    }
}
#endif
