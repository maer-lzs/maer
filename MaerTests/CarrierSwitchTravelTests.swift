// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Was bei einem Traegerwechsel HEUTE schon reist, gemessen statt gelesen.
///
/// Die Annahme hinter A5 lautete, es gebe keinen Voll-Hochschrieb. Gesucht
/// worden war nach `pushAll`, `fullSync`, `resync`: keine Treffer. Der
/// Mechanismus hat aber keinen solchen Namen, er heisst `reconcile()` im
/// `start()` jedes Laeufers, und ein leerer Traeger gewinnt darin jeden
/// Vergleich gegen einen lokalen Eintrag.
///
/// Diese Zeugen halten das fest, weil es sonst beim naechsten Umbau still
/// verschwindet: wenn ein Laeufer den vollen Abgleich aus seinem Start
/// nimmt, verliert der Rueckweg seine Deckung, und kein anderer Fall wuerde
/// rot.
@MainActor
struct CarrierHandoverTravelTests {

    // MARK: - Der Topf

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
        func refresh(by caller: String) async {}
    }

    @Test("ein Traeger, der NICHTS haelt, bekommt den lokalen Hoerstand beim ersten vollen Abgleich")
    func anEmptyCarrierReceivesTheLocalStand() {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        // Die Voraussetzung wird gesetzt und dann zugesichert. Ein
        // Wachposten an dieser Stelle waere ein bestandener Fall, der nichts
        // gemessen hat, und das sieht von aussen genauso aus wie ein Beleg.
        #expect(AppStorageKeys.syncAcrossDevicesEnabled, "ohne den Schalter misst der Fall nichts")
        let carrier = RecordingStandCarrier()
        let sync = PodcastCloudSync(carrier: carrier)
        let id = "rss:handover:\(UUID().uuidString)"
        defer { ListeningStore.clearBackup(id) }

        let now = Date().timeIntervalSince1970 * 1000
        ListeningStore.store(id, entry: [420, now, 3_600])
        #expect(carrier.held.isEmpty, "die Voraussetzung: der neue Traeger haelt nichts")

        sync.reconcile(pushing: true, caller: "handover witness")

        // Genau die Lage nach einem Wechsel: der neue Traeger hat zu diesem
        // Eintrag keinen Zeitstempel, also gewinnt der lokale, und er geht
        // hinaus. Es braucht dafuer keinen eigenen Voll-Hochschrieb.
        #expect(carrier.held[id]?[0] == 420, "der lokale Stand hat den leeren Traeger erreicht")
    }

    // MARK: - Die Listen

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
        func refresh(by caller: String) async {}
    }

    @Test("ein Traeger, der NICHTS haelt, bekommt die ganzen Listen im start des Laeufers")
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

        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                                  ablage: Ablage(directory: directory))
        let list = store.create(name: "Vor dem Wechsel")
        _ = store.add(itemId: "rss:eins", to: list.id)

        // Erst JETZT bekommt der Laeufer den neuen, leeren Traeger, genau
        // wie nach einem Neustart mit umgestelltem Traeger.
        let carrier = RecordingPlaylistCarrier()
        #expect(carrier.snapshot.lists.isEmpty, "die Voraussetzung: der neue Traeger haelt nichts")
        let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store)
        runner.start()

        #expect(carrier.snapshot.lists[list.id]?.itemIds == ["rss:eins"],
                "die ganze Liste hat den leeren Traeger im start erreicht")
    }

    // MARK: - Was der Deckel kostet, und was er NICHT kostet

    @Test("zu einem Traeger mit Decke reisen die TAGE ganz, also ueberleben die Summen den Wechsel")
    func theDaysTravelWholeEvenUnderTheCeiling() {
        // Der Unterschied zwischen ganzem Topf und veroeffentlichtem Topf
        // ist die Frage, ob ein Wechsel zu Apple Zahlen verliert. Er
        // verliert Sekunden je TITEL, die ein anderer Kanal ohnehin traegt,
        // und er verliert keinen einzigen TAG. Die Summen der Statistik
        // stehen auf den Tagen.
        let full = ListeningStatsData(secondsPerDay: ["2026-09-16": 3_600, "2026-09-15": 1_200],
                                      secondsPerItem: ["radio:dlf": 900, "rss:show:ep": 600])
        let published = ListeningStatsSync.publishable(full)
        #expect(published.secondsPerDay == full.secondsPerDay, "kein Tag bleibt zurueck")
        #expect(published.secondsPerItem != full.secondsPerItem,
                "die Voraussetzung: hier faellt ueberhaupt etwas weg, sonst misst der Fall nichts")
        #expect(published.secondsPerItem["radio:dlf"] == 900,
                "was keinen eigenen Kanal hat, reist mit")
    }

    @Test("was ein gedeckelter Traeger NICHT annimmt, ist die abgeschlossene Folge einer abbestellten Sendung")
    func theCappedCarrierDropsFinishedEpisodesOfUnsubscribedShows() {
        // Die einzige gemessene Einbusse des Rueckwegs: zum Dienst bleibt
        // sie liegen, zu Apple nicht. Das ist eine Entscheidung ueber den
        // PLATZ und keine ueber den Wert, und sie gehoert deshalb in den
        // Bericht ueber einen Wechsel, nicht in eine stille Zeile.
        let finished = [100.0, 1_000, 100]
        #expect(!PodcastCloudSync.travels(id: "rss:weg:ep", entry: finished,
                                          isSubscribedShow: { _ in false }))
        #expect(PodcastCloudSync.travels(id: "rss:bleibt:ep", entry: finished,
                                         isSubscribedShow: { _ in true }))
    }
}
#endif
