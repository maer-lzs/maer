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

        // The release still carries the final stand for the NEXT start; it
        // never moves a playback that already runs (no catch-up: a jump
        // while listening is the disturbance, seconds heard twice are not).
        var released = foreign; released.released = true; released.t = now - 5_000
        released.position = 650
        #expect(PlaybackClaimRules.takeoverPosition(claim: released, itemId: "rss:f:ep",
                                                    ownDeviceId: "dev-a", nowMs: now) == 650)
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
        // The beat's length is the carrier's; the rule only compares.
        #expect(PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now - 10_000, nowMs: now, forced: false, heartbeatSeconds: 10))
        #expect(!PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now - 9_000, nowMs: now, forced: false, heartbeatSeconds: 10))
        #expect(PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now - 9_000, nowMs: now, forced: false, heartbeatSeconds: 5))
        #expect(PlaybackClaimRules.shouldRefreshClaim(lastClaimAtMs: now, nowMs: now, forced: true, heartbeatSeconds: 10))
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
        // A claim on a DIFFERENT item pauses too: one account, one listener.
        // A radio station playing here, a podcast started there: the radio
        // stops (radio has no position step, the rule is the same).
        #expect(PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: "item-2", nowMs: now))
        #expect(PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: "radio:rb:x", nowMs: now))
        // An OLDER foreign play on another item does not, nor a release.
        #expect(!PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: "item-2", nowMs: now,
            ownStartedAtMs: now))
        var releasedOther = foreign; releasedOther.released = true
        #expect(!PlaybackClaimRules.shouldPause(
            claim: releasedOther, ownDeviceId: "dev-a", playingItemId: "item-2", nowMs: now))
        // Rot-Probe of the old rule, as a closure over the same claim: the
        // title condition kept item-2 playing, which is the measured 12 s
        // of two titles at once.
        let oldRule: (PlaybackClaim, String) -> Bool = { claim, playing in
            claim.deviceId != "dev-a" && claim.itemId == playing
                && PlaybackClaimRules.isFresh(claim, nowMs: now)
        }
        #expect(!oldRule(foreign, "item-2") && oldRule(foreign, "item-1"))
        // A stale claim is a previous session, not a takeover.
        #expect(!PlaybackClaimRules.shouldPause(
            claim: claim("dev-b", "item-1", ageSeconds: PlaybackClaimRules.freshSeconds + 1),
            ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.shouldPause(
            claim: nil, ownDeviceId: "dev-a", playingItemId: "item-1", nowMs: now))
        #expect(!PlaybackClaimRules.shouldPause(
            claim: foreign, ownDeviceId: "dev-a", playingItemId: nil, nowMs: now))
    }

    /// The newest PLAY wins. Measured on the switch back: the device that
    /// had just taken over was stopped by the other side's heartbeat,
    /// older than its own play but fresh. A foreign claim stops this
    /// device only when a person pressed play there after this playback
    /// started; a heartbeat never does, because heartbeats of both sides
    /// cross in the delivery seconds and would stop both.
    @Test("the newest play wins; a heartbeat never pauses")
    func newestPlayWins() {
        let t1 = now - 8_000                     // this device pressed play
        let olderPlay = PlaybackClaim(deviceId: "dev-b", itemId: "item-1", t: t1 - 20_000)
        let newerPlay = PlaybackClaim(deviceId: "dev-b", itemId: "item-1", t: t1 + 4_000)
        // A heartbeat written AFTER this device's play, carrying the OLDER
        // play of the other device.
        var newerBeat = newerPlay; newerBeat.playAt = t1 - 20_000
        // An older play, still fresh, does not stop the device that just took over.
        #expect(!PlaybackClaimRules.shouldPause(claim: olderPlay, ownDeviceId: "dev-a",
                                                playingItemId: "item-1", nowMs: now,
                                                ownStartedAtMs: t1))
        // A newer play does.
        #expect(PlaybackClaimRules.shouldPause(claim: newerPlay, ownDeviceId: "dev-a",
                                               playingItemId: "item-1", nowMs: now,
                                               ownStartedAtMs: t1))
        // A newer HEARTBEAT does not: only a person may stop the other side.
        #expect(!PlaybackClaimRules.shouldPause(claim: newerBeat, ownDeviceId: "dev-a",
                                                playingItemId: "item-1", nowMs: now,
                                                ownStartedAtMs: t1))
        // Rot-Probe: without the own start (the old rule) the older play
        // pauses, which is exactly the failed switch back.
        #expect(PlaybackClaimRules.shouldPause(claim: olderPlay, ownDeviceId: "dev-a",
                                               playingItemId: "item-1", nowMs: now))
        // The kind travels: a beat stays a beat, an old build without the
        // field counts as a play so it can still take over.
        #expect(PlaybackClaim.from(plist: newerBeat.plist)?.playTime == t1 - 20_000)
        #expect(PlaybackClaim.from(plist: newerPlay.plist)?.playTime == t1 + 4_000)
        #expect(PlaybackClaim.from(plist: ["device": "dev-b", "item": "i", "t": 1.0])?.playTime == 1)
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
        let a = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-a" },
                                  now: { clockA += 1; return clockA })
        var clockB: Double = 2000
        let b = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-b" },
                                  now: { clockB += 1; return clockB })

        var aHeard: PlaybackClaim?
        a.onForeignClaim = { aHeard = $0 }
        var bHeard: PlaybackClaim?
        b.onForeignClaim = { bHeard = $0 }

        a.claim(itemId: "item-1")
        a.poll()
        #expect(aHeard == nil)          // the own claim never fires the hook
        #expect(a.current?.deviceId == "dev-a")

        // B takes over in its OWN key; polling, B sees A's older claim (the
        // rule decides it is older, the hook still hears it), A hears B.
        b.claim(itemId: "item-1")
        b.poll()
        #expect(bHeard?.deviceId == "dev-a")
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
        let a = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-a" },
                                  now: { clock += 1; return clock })
        let b = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-b" },
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
        let a = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-a" },
                                  now: { clockA += 1; return clockA })
        var clockB: Double = 2000
        let b = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-b" },
                                  now: { clockB += 1; return clockB })

        // Own claim → release marks it withdrawn, in the OWN key.
        a.claim(itemId: "item-1")
        a.release(itemId: "item-1")
        var stored = PlaybackClaim.from(plist: cloud.storage[KeyValueClaimCarrier.key(for: "dev-a")])
        #expect(stored?.released == true && stored?.deviceId == "dev-a")

        // B takes over; A's pause must NOT tear B's claim down: B's claim
        // lives in B's key, A never writes it.
        b.claim(itemId: "item-1")
        a.release(itemId: "item-1")
        stored = PlaybackClaim.from(plist: cloud.storage[KeyValueClaimCarrier.key(for: "dev-b")])
        #expect(stored?.released == false && stored?.deviceId == "dev-b")
        // The key of the older builds is read, never written.
        #expect(cloud.storage[KeyValueClaimCarrier.claimKey] == nil)
    }

    /// One key per device: B's play lands between two of A's heartbeats
    /// and A still sees it, at every offset. With the single key the
    /// heartbeat written after B's play threw the play away (measured on
    /// two devices: both kept playing).
    @Test("a play between two foreign heartbeats is seen at every offset")
    func playSurvivesForeignHeartbeats() {
        let cloud = UserChoiceFakeCloud()
        var clock: Double = 1_000_000
        let a = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-a" }, now: { clock })
        let b = PlaybackClaimSync(carrier: KeyValueClaimCarrier(cloud: cloud), deviceId: { "dev-b" }, now: { clock })
        var aHeard: [PlaybackClaim] = []
        a.onForeignClaim = { aHeard.append($0) }
        for offset in stride(from: 1_000.0, through: 9_000.0, by: 1_000) {
            aHeard = []
            cloud.storage = [:]
            // A plays since t0 and beats every 10 s.
            let t0 = clock
            a.claim(itemId: "item-1", playAt: t0)
            clock += offset
            // B presses play between two of A's beats.
            b.claim(itemId: "item-1", playAt: clock)
            let bPlay = clock
            clock = t0 + 10_000
            a.claim(itemId: "item-1", playAt: t0)          // A's next beat
            a.poll()
            #expect(aHeard.last?.deviceId == "dev-b", "offset \(offset): A must hear B")
            #expect(aHeard.last?.playTime == bPlay)
            #expect(PlaybackClaimRules.shouldPause(
                claim: aHeard.last, ownDeviceId: "dev-a", playingItemId: "item-1",
                nowMs: clock, ownStartedAtMs: t0), "offset \(offset): A must stand down")
            // And B, seeing A's beat with the OLDER play, does not.
            #expect(!PlaybackClaimRules.shouldPause(
                claim: PlaybackClaim.from(plist: cloud.storage[KeyValueClaimCarrier.key(for: "dev-a")]),
                ownDeviceId: "dev-b", playingItemId: "item-1",
                nowMs: clock, ownStartedAtMs: bPlay))
        }
        // Rot-Probe: in ONE shared key A's later beat replaces B's play.
        var shared: [String: Any] = PlaybackClaim(deviceId: "dev-b", itemId: "item-1", t: 5, playAt: 5).plist
        shared = PlaybackClaim(deviceId: "dev-a", itemId: "item-1", t: 6, playAt: 1).plist
        #expect(PlaybackClaim.from(plist: shared)?.deviceId == "dev-a")
    }

    /// D10 d: the poll is the promise of the takeover on a locked, playing
    /// device (no push reaches it), so it runs every ten seconds while
    /// playing; sync and heartbeat keep their thirty.
    @Test("der Tick ist zehn Sekunden: Poll jeden Tick beim Spielen, sonst jeden dritten; Sync jeden dritten")
    func tickRules() {
        #expect(PlaybackClaimRules.tickSeconds == 10)
        #expect(PlaybackClaimRules.ticksPerSync == 3)
        #expect((1...6).map { PlaybackClaimRules.syncDue(tick: $0) } == [false, false, true, false, false, true])
        #expect((1...3).allSatisfy { PlaybackClaimRules.pollDue(tick: $0, playing: true) })
        #expect((1...3).map { PlaybackClaimRules.pollDue(tick: $0, playing: false) } == [false, false, true])
        #expect(PlaybackClaimRules.tickSeconds * Double(PlaybackClaimRules.ticksPerSync) == 30, "the sync cadence is unchanged")
        // A cadence of the carrier's, counted in ticks: ten seconds is
        // every tick, thirty every third, five (shorter than a tick) every
        // tick, forty-five rounds down to every fourth.
        #expect((1...3).allSatisfy { PlaybackClaimRules.due(tick: $0, everySeconds: 10) })
        #expect((1...6).map { PlaybackClaimRules.due(tick: $0, everySeconds: 30) } == [false, false, true, false, false, true])
        #expect((1...3).allSatisfy { PlaybackClaimRules.due(tick: $0, everySeconds: 5) })
        #expect((1...4).map { PlaybackClaimRules.due(tick: $0, everySeconds: 45) } == [false, false, false, true])
    }

    /// The numbers that used to stand in the rule for every way now stand
    /// at the way they came from: the key-value carriers keep their
    /// measured ten seconds of heartbeat and pull and their minute of
    /// sending, the service chooses its own.
    @Test("der Takt kommt vom Traeger, nicht aus einer Konstanten") @MainActor
    func theCadenceIsTheCarriers() {
        let keyValue = KeyValueClaimCarrier(cloud: InMemoryCloudStore())
        #expect(keyValue.heartbeatSeconds == 10)
        #expect(PlaybackClaimSync(carrier: keyValue, deviceId: { "dev-a" }, deviceName: { "x" }, now: { 0 }).heartbeatSeconds == 10)
        // The gate lives in the runner: within the beat a second claim is
        // not written, a forced one always is, and the runner keeps the
        // moment, not the player.
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let recording = ClaimCarrierTests.RecordingCarrier()
        var clock: Double = 1_000_000
        let sync = PlaybackClaimSync(carrier: recording, deviceId: { "dev-a" }, deviceName: { "x" }, now: { clock })
        sync.claimIfDue(itemId: "rss:f:ep", forced: true)
        clock += 5_000
        sync.claimIfDue(itemId: "rss:f:ep", forced: false)
        #expect(recording.written.count == 1, "within the beat the heartbeat does not write")
        clock += 5_000
        sync.claimIfDue(itemId: "rss:f:ep", forced: false)
        #expect(recording.written.count == 2, "the beat is due")
        sync.claimIfDue(itemId: "rss:f:ep", forced: true)
        #expect(recording.written.count == 3, "an event always writes")
        #expect(sync.lastClaimAtMs == clock)
        let stands = KeyValueStandCarrier(cloud: InMemoryCloudStore(), spacingSeconds: 0)
        #expect(stands.pullSeconds == 10)
        #expect(stands.sendCadenceSeconds == 60)
        let runner = PodcastCloudSync(carrier: stands)
        #expect((1...3).allSatisfy { runner.pullDue(tick: $0) }, "the iCloud pot is asked every tick while playing")
        #expect(runner.sendCadenceSeconds == 60)
    }
}
#endif
