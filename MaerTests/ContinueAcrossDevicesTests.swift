// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Continuing between two devices. A silent, loaded player follows a stand
/// another device wrote later. Every own stand and claim is stamped by a
/// hybrid clock in `atMs`: past everything this device has seen of the
/// title, else its own clock, so a clock that runs ahead on the other
/// device cannot win over a later hand-over, and an hour heard offline
/// still wins by its time.
struct ContinueAcrossDevicesTests {
    // MARK: d: the silent player follows

    @Test("a silent, loaded player follows a stand written later elsewhere; a running, loading, older or equal one does not move")
    func theSilentPlayerFollows() {
        let follow = { (playing: Bool, loaded: Bool, position: Double, atMs: Double) in
            SyncRules.silentFollow(isPlaying: playing, isLoaded: loaded, position: position, atMs: atMs,
                                   ownStandMs: 1_000, currentTime: 100)
        }
        #expect(follow(false, true, 600, 2_000) == 600, "later elsewhere: it follows")
        #expect(follow(false, true, 600, 500) == nil, "older: it stays")
        #expect(follow(true, true, 600, 2_000) == nil, "running: it stays")
        #expect(follow(false, false, 600, 2_000) == nil, "loading: it takes the store at the end of its load")
        #expect(follow(false, true, 101, 2_000) == nil, "the same stand: nothing moves")
    }

    @Test("Fence: the kept standby asks the player to follow, and the follow jumps without a write", .needsTheSources)
    func theKeptStandbyFollows() throws {
        let coordinator = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        let refresh = try #require(coordinator.range(of: "func refreshStandbyFromTruth() async {"))
        let keep = try #require(coordinator.range(of: "case .keep:", range: refresh.upperBound..<coordinator.endIndex))
        let next = try #require(coordinator.range(of: "case .clearFinished:", range: keep.upperBound..<coordinator.endIndex))
        #expect(coordinator[keep.upperBound..<next.lowerBound].contains("followStoredStand()"))
        let model = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8))
        let follow = try #require(model.range(of: "func followStoredStand()"))
        let body = model[follow.upperBound...].prefix(1400)
        #expect(body.contains("SyncRules.silentFollow("), "the follow asks the rule")
        #expect(body.contains("userInitiated: false"), "the follow jumps without a write, a claim or the pot")
    }

    // MARK: e: the hybrid clock

    @Test("the hybrid stamp: past everything seen of the title, else the own clock")
    func theHybridStamp() {
        #expect(SyncRules.hybridStamp(nowMs: 1_000, seenMs: nil) == 1_000, "nothing seen: the clock, as an older app")
        #expect(SyncRules.hybridStamp(nowMs: 1_000, seenMs: 500) == 1_000, "the clock is ahead of what was seen")
        #expect(SyncRules.hybridStamp(nowMs: 1_000, seenMs: 61_000) == 61_001, "a clock that ran ahead elsewhere is passed")
    }

    @Test("two devices: the Mac runs 60 s ahead, after the hand-over the iPhone keeps its stand; an hour heard offline later on the Mac wins")
    func twoDevices() {
        let phoneNow: Double = 10_000_000
        // The Mac, 60 s ahead, releases at its own clock.
        let macRelease = phoneNow + 60_000
        // The iPhone has seen the release and plays on for 10 s.
        let phoneStand = SyncRules.hybridStamp(nowMs: phoneNow + 10_000, seenMs: macRelease)
        #expect(phoneStand > macRelease, "the iPhone's own stand is newer than what it saw")
        #expect(SyncRules.storedStand(position: 300, atMs: macRelease, ownStandMs: phoneStand, currentTime: 400) == .older,
                "the Mac's older release does not move the iPhone back")
        // Later the Mac hears an hour offline, it has seen only up to its own release.
        let macOffline = SyncRules.hybridStamp(nowMs: phoneNow + 3_660_000, seenMs: macRelease)
        #expect(macOffline > phoneStand, "the later hour wins by its time")
    }

    @Test("a release older than the stand held of its title does not become current; a running claim always does")
    func anOldReleaseIsNotTaken() {
        let release = PlaybackClaim(deviceId: "mac", itemId: "x", t: 5_000, released: true, position: 300)
        #expect(!PlaybackClaimRules.takesRelease(release, heldStandMs: 6_000))
        #expect(PlaybackClaimRules.takesRelease(release, heldStandMs: 4_000))
        #expect(PlaybackClaimRules.takesRelease(release, heldStandMs: nil))
        let running = PlaybackClaim(deviceId: "mac", itemId: "x", t: 5_000, position: 300)
        #expect(PlaybackClaimRules.takesRelease(running, heldStandMs: 6_000))
    }

    @Test("the age of a claimed position counts from its arrival here: a clock 20 minutes behind, received a minute ago, still starts there")
    func theAgeCountsFromArrival() {
        let nowMs: Double = 100_000_000
        let claim = PlaybackClaim(deviceId: "mac", itemId: "x", t: nowMs - 20 * 60_000, position: 300)
        #expect(PlaybackClaimRules.takeoverPosition(claim: claim, itemId: "x", ownDeviceId: "phone", nowMs: nowMs,
                                                    receivedMs: nowMs - 60_000) == 300)
        #expect(PlaybackClaimRules.takeoverPosition(claim: claim, itemId: "x", ownDeviceId: "phone", nowMs: nowMs) == nil,
                "without an arrival the claim's own time counts, as before")
    }

    @Test("Fence: no own stand and no claim is stamped with the bare clock", .needsTheSources)
    func noBareClock() throws {
        let sync = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/PlaybackClaimSync.swift"), encoding: .utf8))
        #expect(!sync.contains("t: now()"), "a claim or release is stamped with the bare clock")
        let model = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        let halt = try #require(model.range(of: "func recordHaltStand() {"))
        #expect(model[halt.upperBound...].prefix(400).contains("ownStampMs("), "the halt stamps with the hybrid clock")
        #expect(!model.contains("atMs: now * 1000"), "the tick stamps with the bare clock")
    }
}
#endif
