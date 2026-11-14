// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What already travels at a carrier switch TODAY, measured instead of read.
///
/// An earlier assumption was that there is no full push-up. It had been
/// searched for `pushAll`, `fullSync`, `resync`: no hits. The
/// mechanism has no such name, though, it is called `reconcile()` in the
/// `start()` of every runner, and an empty carrier wins every
/// comparison against a local entry in it.
///
/// These witnesses pin that down, because otherwise it silently disappears
/// at the next rework: if a runner takes the full sync out of its start,
/// the way back loses its coverage, and no other case would turn
/// red.
@MainActor
struct CarrierSwitchTravelTests {

    // MARK: - The pot

    private final class RecordingStandCarrier: StandCarrier {
        let name = "handover-fake"
        var hasRoomLimit = false
        var held: [String: [Double]] = [:]
        var writes: [(upserts: [String: [Double]], removing: Set<String>, by: String)] = []

        func stands() -> [String: [Double]] { held }
        func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
            writes.append((upserts, removing, caller))
            for id in removing { held[id] = nil }
            for (id, entry) in upserts { held[id] = entry }
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("a carrier that holds NOTHING gets the local listening state at the first full sync")
    func anEmptyCarrierReceivesTheLocalStand() {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        // The precondition is set and then ensured. A
        // sentinel at this point would be a passed case that measured nothing,
        // and from the outside that looks exactly like evidence.
        #expect(AppStorageKeys.syncAcrossDevicesEnabled, "ohne den Schalter misst der Fall nichts")
        let carrier = RecordingStandCarrier()
        let sync = PodcastCloudSync(carrier: carrier)
        let id = "rss:handover:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }

        let now = Date().timeIntervalSince1970 * 1000
        ListeningStore.store(id, entry: [420, now, 3_600])
        #expect(carrier.held.isEmpty, "die Voraussetzung: der neue Traeger haelt nichts")

        sync.reconcile(pushing: true, caller: "handover witness")

        // Exactly the situation after a switch: the new carrier has no timestamp
        // for this entry, so the local one wins, and it goes
        // out. No full push-up of its own is needed for that.
        #expect(carrier.held[id]?[0] == 420, "der lokale Stand hat den leeren Traeger erreicht")
    }

    // MARK: - The lists

    private final class RecordingPlaylistCarrier: PlaylistCarrier {
        let name = "handover-fake"
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores: [MaerPlaylistMerge.Snapshot] = []
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
            self.snapshot = snapshot
            stores.append(snapshot)
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("a carrier that holds NOTHING gets the whole lists in the start of the runner")
    func anEmptyCarrierReceivesTheWholePlaylists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handover-lists-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }

        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let list = store.create(name: "Vor dem Wechsel")
        _ = store.add(itemId: "rss:eins", to: list.id)

        // Only NOW does the runner get the new, empty carrier, exactly
        // as after a restart with a switched carrier.
        let carrier = RecordingPlaylistCarrier()
        #expect(carrier.snapshot.lists.isEmpty, "die Voraussetzung: der neue Traeger haelt nichts")
        let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, idFormSettled: { true })
        runner.start()

        #expect(carrier.snapshot.lists[list.id]?.itemIds == ["rss:eins"],
                "die ganze Liste hat den leeren Traeger im start erreicht")
    }

    // MARK: - What the cap costs, and what it does NOT cost

    @Test("to a carrier with a cap the DAYS travel in full, so the sums survive the switch")
    func theDaysTravelWholeEvenUnderTheCeiling() {
        // The difference between whole pot and published pot
        // is the question whether a switch to Apple loses numbers. It
        // loses seconds per TITLE, which another channel carries anyway,
        // and it does not lose a single DAY. The sums of the statistics
        // stand on the days.
        let full = ListeningStatsData(secondsPerDay: ["2026-09-16": 3_600, "2026-09-15": 1_200],
                                      secondsPerItem: ["radio:dlf": 900, "rss:show:ep": 600])
        let published = ListeningStatsSync.publishable(full)
        #expect(published.secondsPerDay == full.secondsPerDay, "kein Tag bleibt zurueck")
        #expect(published.secondsPerItem != full.secondsPerItem,
                "die Voraussetzung: hier faellt ueberhaupt etwas weg, sonst misst der Fall nichts")
        #expect(published.secondsPerItem["radio:dlf"] == 900,
                "was keinen eigenen Kanal hat, reist mit")
    }

    @Test("what a capped carrier does NOT accept is the finished episode of an unsubscribed show")
    func theCappedCarrierDropsFinishedEpisodesOfUnsubscribedShows() {
        // The only measured loss of the way back: to the service it stays
        // in place, to Apple it does not. That is a decision about
        // SPACE and none about value, and it therefore belongs in the
        // report about a switch, not in a silent line.
        let finished = [100.0, 1_000, 100]
        #expect(!PodcastCloudSync.travels(id: "rss:weg:ep", entry: finished,
                                          isSubscribedShow: { _ in false }))
        #expect(PodcastCloudSync.travels(id: "rss:bleibt:ep", entry: finished,
                                         isSubscribedShow: { _ in true }))
    }
}
#endif
