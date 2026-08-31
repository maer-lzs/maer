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

    /// Die Reise-Regel der KVS-Raeumung: fertig UND abbestellt verlaesst
    /// den Reise-Topf, sonst NIE. Der bindende Zaun woertlich: nie faellt
    /// ein Stand einer abonnierten oder unfertigen Folge.
    @Test("nur fertige Folgen abbestellter Shows verlassen den Reise-Topf")
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
        // Zweifel (weder Sentinel noch gespeicherte Dauer): bleibt.
        #expect(PodcastCloudSync.travels(id: "rss:weg:g5", entry: [5_000, 1_000],
                                         isSubscribedShow: abonniert))
        // Nicht-Podcast-Klassen reisen immer (kein Abo-Begriff).
        for id in ["abspod:x:y", "lv:123", "local:datei", "gut:9"] {
            #expect(PodcastCloudSync.travels(id: id, entry: fertig,
                                             isSubscribedShow: { _ in false }))
        }
    }

    /// Die Grabstein-Frage, beantwortet durch ABLEITUNG statt Grabstein:
    /// geraeumt und wieder abonniert heisst, der lokale Stand reist beim
    /// naechsten Abgleich einfach wieder; nichts blockiert die Rueckkehr,
    /// und die Raeumung fasst nur den Cloud-Topf an.
    /// Jeder Schreibweg laeuft durch die Regel: was der Einzelweg
    /// hochschreiben will (pushLocal), muss reisen duerfen. Sonst legte
    /// ein spaeter Anfass einer fertigen Folge einer abbestellten Show
    /// den geraeumten Eintrag zurueck in den Topf.
    @Test("auch der Einzel-Schreibweg respektiert die Reise-Regel")
    func singleKeyPathHonoursTravelRule() {
        let fertig: [Double] = [ProgressMark.playedSentinel, 9_000]
        // mergeSingle wuerde hochschreiben (lokal neuer, Cloud leer) ...
        let outcome = PodcastCloudSync.mergeSingle(local: fertig, cloud: nil)
        #expect(outcome == .pushLocal(fertig))
        // ... aber die Reise-Regel verneint, und der Weg bricht ab (die
        // Verdrahtung steht im pushLocal-Zweig; hier steht die Regel, die
        // er fragt).
        #expect(!PodcastCloudSync.travels(id: "rss:weg:g9", entry: fertig,
                                          isSubscribedShow: { _ in false }))
    }

    @Test("Wieder-Abonnieren bringt den geraeumten Stand von selbst zurueck")
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
