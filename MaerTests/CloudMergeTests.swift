// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// Newest-wins merge semantics of the podcast iCloud sync, the
/// equivalence of the targeted single-id merge, and the double-start guard.
@MainActor
struct CloudMergeTests {

    // MARK: - Full merge (newest wins, no ping-pong)

    /// A receive-only pass finds the local side "newer" while this device
    /// plays; that is not a change and writes no ring entry. Only what was
    /// taken in or actually pushed counts.
    @Test("A sync without movement writes no ring entry")
    func ringEntryOnlyForWhatMoved() {
        #expect(PodcastCloudSync.ringCounters(down: 0, up: 3, pushing: false) == nil)
        #expect(PodcastCloudSync.ringCounters(down: 0, up: 0, pushing: true) == nil)
        let pushed = PodcastCloudSync.ringCounters(down: 0, up: 3, pushing: true)
        #expect(pushed?.down == 0 && pushed?.up == 3)
        let taken = PodcastCloudSync.ringCounters(down: 2, up: 5, pushing: false)
        #expect(taken?.down == 2 && taken?.up == 0)
    }

    @Test func newerTimestampWinsInBothDirections() {
        let outcome = PodcastCloudSync.merge(
            local: ["a": [10, 1000], "b": [20, 5000]],
            cloud: ["a": [99, 2000], "b": [88, 4000]]
        )
        // a: cloud newer → to local; b: local newer → to cloud.
        #expect(outcome.toLocal["a"] == [99, 2000])
        #expect(outcome.toLocal["b"] == nil)
        #expect(outcome.toCloud["b"] == [20, 5000])
        #expect(outcome.toCloud["a"] == nil)
    }

    /// Sending has its own budget: during playback without a change of
    /// phase the pot is written at most once a minute, whatever arrives
    /// from the other device in between. Measured before: four whole-pot
    /// writes in 25 seconds.
    @Test("sixty seconds of ticks send the pot once; events always send")
    func sendBudgetIsOnePerMinute() {
        var lastSent: Double = 0
        var sends = 0
        // Twelve five-second ticks, no event.
        for tick in 1...12 {
            let now = Double(tick) * 5_000
            if CloudSendRules.shouldSend(deliberate: false, lastSentAtMs: lastSent, nowMs: now, cadenceSeconds: 60) {
                sends += 1; lastSent = now
            }
        }
        #expect(sends == 1, "the cadence sends once in sixty seconds")
        // A deliberate occasion sends at once, even right after a send.
        #expect(CloudSendRules.shouldSend(deliberate: true, lastSentAtMs: 60_000, nowMs: 60_500, cadenceSeconds: 60))
        // Red probe: the old form (send on every occasion) would have
        // sent twelve times.
        #expect(!CloudSendRules.shouldSend(deliberate: false, lastSentAtMs: 60_000, nowMs: 60_500, cadenceSeconds: 60))
    }

    /// ONE positive list says whose stand lives in the pot, and the start
    /// pull before playback asks it. Measured gap: the pull knew two
    /// prefixes, so a catalogue book on the other device started at the
    /// mark of the last full reconcile instead of the pot's stand.
    @Test("the pot list names every travelling class, and radio and server music are not in it")
    func potCarriesEveryTravellingClass() {
        for id in ["rss:feed:guid", "abspod:x", "local:file", "lv:123", "lva:work#3",
                   "jam:track", "gut:42"] {
            #expect(PodcastCloudSync.potCarries(id), "\(id) must travel")
        }
        for id in ["radio:rb:x", "sub:song:1", "jf:item", "abs:book"] {
            #expect(!PodcastCloudSync.potCarries(id), "\(id) has its own truth or none")
        }
        // Red probe: the old two-prefix check missed every catalogue class.
        let old: (String) -> Bool = { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") }
        #expect(!old("lv:123") && PodcastCloudSync.potCarries("lv:123"))
    }

    /// A burst of writers within the spacing becomes ONE trailing write;
    /// a lone write goes at once. Measured: four whole pots in six seconds.
    @Test("a burst of pot writes collapses to one trailing write")
    func burstCollapsesToOneTrailingWrite() {
        // First write: nothing before it, goes now.
        #expect(CloudSendRules.trailingWait(lastWriteAtMs: 0, nowMs: 100_000) == nil)
        // Three more within six seconds: each waits for the rest of the spacing.
        #expect(CloudSendRules.trailingWait(lastWriteAtMs: 100_000, nowMs: 101_000) == 4)
        let rest = CloudSendRules.trailingWait(lastWriteAtMs: 100_000, nowMs: 104_600) ?? -1
        #expect(abs(rest - 0.4) < 0.001)
        // After the spacing: at once again.
        #expect(CloudSendRules.trailingWait(lastWriteAtMs: 100_000, nowMs: 105_000) == nil)
        // Red probe: the old form wrote every time, i.e. never waited.
        #expect(CloudSendRules.trailingWait(lastWriteAtMs: 100_000, nowMs: 100_001) != nil)
    }

    /// A device that was away for a day comes back to a union without
    /// loss: what it wrote meanwhile travels up, what the others wrote
    /// travels down, and a tombstone written in between is respected,
    /// not resurrected by the returning device's older mark.
    @Test("after a day offline the merge is a union, tombstones respected")
    func offlineDayMergesToAUnion() {
        let day: Double = 86_400_000
        let t0: Double = 1_700_000_000_000
        // Device B (returning) kept listening offline: two of its own
        // marks advanced, one episode it never touched, and one it marked
        // played BEFORE the other device marked it unplayed.
        let local: [String: [Double]] = [
            "ep-offline-1": [1_200, t0 + day / 2, 3_600],
            "ep-offline-2": [2_592_000, t0 + day / 3, 3_600],
            "ep-old": [300, t0 - day],
            "ep-tombstoned": [2_592_000, t0 + 1_000, 1_800],
        ]
        // The pot as the other device left it during that day.
        let cloud: [String: [Double]] = [
            "ep-cloud-new": [500, t0 + day / 4, 2_400],
            "ep-old": [900, t0 + day / 5, 3_600],
            "ep-tombstoned": [0, t0 + 2_000],
            "ep-offline-1": [100, t0],
        ]
        let outcome = PodcastCloudSync.merge(local: local, cloud: cloud)
        // Up: B's fresher own marks, and what the pot never had.
        #expect(outcome.toCloud["ep-offline-1"] == [1_200, t0 + day / 2, 3_600])
        #expect(outcome.toCloud["ep-offline-2"] == [2_592_000, t0 + day / 3, 3_600])
        // Down: the other device's newer mark and the episode B never had.
        #expect(outcome.toLocal["ep-old"] == [900, t0 + day / 5, 3_600])
        #expect(outcome.toLocal["ep-cloud-new"] == [500, t0 + day / 4, 2_400])
        // The tombstone is newer than B's played mark: B follows it (the
        // known duration rides along, as every adopted entry keeps it).
        #expect(outcome.toLocal["ep-tombstoned"]?.prefix(2) == [0, t0 + 2_000])
        #expect(outcome.toCloud["ep-tombstoned"] == nil, "the older played mark must not resurrect")
        // Nothing is lost: every id ends on both sides.
        let union = Set(local.keys).union(cloud.keys)
        let afterCloud = Set(cloud.keys).union(outcome.toCloud.keys)
        let afterLocal = Set(local.keys).union(outcome.toLocal.keys)
        #expect(afterCloud == union && afterLocal == union)
    }

    @Test("Identical state produces NO writes (no ping-pong)")
    func equalTimestampsWriteNothing() {
        let outcome = PodcastCloudSync.merge(
            local: ["a": [10, 1000]],
            cloud: ["a": [10, 1000]]
        )
        #expect(outcome.toLocal.isEmpty)
        #expect(outcome.toCloud.isEmpty)
    }

    @Test func oneSidedEntriesPropagate() {
        let outcome = PodcastCloudSync.merge(
            local: ["onlyLocal": [5, 100]],
            cloud: ["onlyCloud": [7, 200]]
        )
        #expect(outcome.toCloud["onlyLocal"] == [5, 100])
        #expect(outcome.toLocal["onlyCloud"] == [7, 200])
    }

    // MARK: - Single-id merge vs full scan

    @Test("Single-id merge decides exactly like the full scan for value-vs-value")
    func singleMergeMatchesFullScan() {
        let cases: [(local: [Double]?, cloud: [Double]?)] = [
            ([10, 1000], [99, 2000]),   // cloud newer
            ([20, 5000], [88, 4000]),   // local newer
            ([10, 1000], [10, 1000]),   // equal
            ([5, 100], nil),            // only local
        ]
        for c in cases {
            let full = PodcastCloudSync.merge(
                local: c.local.map { ["id": $0] } ?? [:],
                cloud: c.cloud.map { ["id": $0] } ?? [:]
            )
            let single = PodcastCloudSync.mergeSingle(local: c.local, cloud: c.cloud)
            switch single {
            case .adoptCloud(let v): #expect(full.toLocal["id"] == v)
            case .pushLocal(let v): #expect(full.toCloud["id"] == v)
            case .none:
                #expect(full.toLocal.isEmpty)
                #expect(full.toCloud.isEmpty)
            case .pushTombstone:
                Issue.record("tombstone must not occur for value-vs-value cases")
            }
        }
    }

    @Test("Local delete (mark unplayed) pushes a tombstone instead of restoring the old cloud value")
    func localDeletePushesTombstone() {
        // The full scan would restore the cloud value locally; the single-id
        // path deliberately differs: a deleted key means "unplayed", so a fresh
        // zero must win and propagate.
        let single = PodcastCloudSync.mergeSingle(local: nil, cloud: [600, 9999])
        #expect(single == .pushTombstone)
    }

    // MARK: - Double start (logout→login)

    @Test func doubleStartRegistersAtMostOneObserver() {
        let sync = PodcastCloudSync.shared
        sync.start()
        sync.start()
        #expect(sync.observerRegistrations <= 1)
    }

    /// The travel rule of the KVS cleanup: finished AND unsubscribed leaves
    /// the travel pot, otherwise NEVER. The binding fence, verbatim: the
    /// stand of a subscribed or unfinished episode never falls out.
    @Test("only finished episodes of unsubscribed shows leave the travel pot")
    func travelMembershipIsDerived() {
        let abonniert: (String) -> Bool = { $0 == "aboKey" }
        let fertig: [Double] = [ProgressMark.playedSentinel, 1_000]
        let unfertig: [Double] = [120, 1_000]
        #expect(PodcastCloudSync.travels(id: "rss:aboKey:g1", entry: fertig,
                                         isSubscribedShow: abonniert))
        #expect(PodcastCloudSync.travels(id: "rss:aboKey:g2", entry: unfertig,
                                         isSubscribedShow: abonniert))
        #expect(PodcastCloudSync.travels(id: "rss:weg:g3", entry: unfertig,
                                         isSubscribedShow: abonniert))
        #expect(!PodcastCloudSync.travels(id: "rss:weg:g4", entry: fertig,
                                          isSubscribedShow: abonniert))
        // Doubt (neither sentinel nor stored duration): it stays.
        #expect(PodcastCloudSync.travels(id: "rss:weg:g5", entry: [5_000, 1_000],
                                         isSubscribedShow: abonniert))
        // Non-podcast classes always travel (no subscription notion).
        for id in ["abspod:x:y", "lv:123", "local:datei", "gut:9"] {
            #expect(PodcastCloudSync.travels(id: id, entry: fertig,
                                             isSubscribedShow: { _ in false }))
        }
    }

    /// The tombstone question, answered by DERIVATION instead of a tombstone:
    /// cleaned up and subscribed again means the local stand simply travels
    /// again at the next sync; nothing blocks the return, and the cleanup
    /// touches only the cloud pot.
    /// Every write path runs through the rule: what the single path wants
    /// to write up (pushLocal) must be allowed to travel. Otherwise a late
    /// touch of a finished episode of an unsubscribed show would put the
    /// cleaned-up entry back into the pot.
    @Test("the single write path also respects the travel rule")
    func singleKeyPathHonoursTravelRule() {
        let fertig: [Double] = [ProgressMark.playedSentinel, 9_000]
        // mergeSingle would write up (local newer, cloud empty) ...
        let outcome = PodcastCloudSync.mergeSingle(local: fertig, cloud: nil)
        #expect(outcome == .pushLocal(fertig))
        // ... but the travel rule says no, and the path stops (the wiring
        // is in the pushLocal branch; here is the rule it asks).
        #expect(!PodcastCloudSync.travels(id: "rss:weg:g9", entry: fertig,
                                          isSubscribedShow: { _ in false }))
    }

    @Test("Subscribing again brings the cleaned-up stand back by itself")
    func resubscribeBringsTheStandBack() {
        let fertig: [Double] = [ProgressMark.playedSentinel, 2_000]
        let geraeumt = PodcastCloudSync.cleaned(cloud: ["rss:weg:g1": fertig],
                                                isSubscribedShow: { _ in false })
        #expect(geraeumt.kept.isEmpty && geraeumt.droppedCount == 1)
        let outcome = PodcastCloudSync.merge(local: ["rss:weg:g1": fertig],
                                             cloud: [:])
        #expect(outcome.toCloud["rss:weg:g1"] == fertig,
                "der geraeumte Stand kaeme nach dem Wieder-Abo nicht zurueck")
        #expect(PodcastCloudSync.travels(id: "rss:weg:g1", entry: fertig,
                                         isSubscribedShow: { $0 == "weg" }))
    }
}
#endif
