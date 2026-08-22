// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Takeover semantics (3e4db13): play on the standby pointer claims; the
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
