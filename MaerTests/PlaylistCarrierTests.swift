// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The playlists travel through a carrier; the rule (`MaerPlaylistMerge`)
/// does not. The key-value carrier keeps the ONE consolidated blob and the
/// tombstones, reads them back as a snapshot and writes a snapshot back;
/// the factory chooses it today, like the pot's, the claim's and the
/// statistics' factories choose theirs.
@MainActor
struct PlaylistCarrierTests {
    private var sample: MaerPlaylistMerge.Snapshot {
        var snap = MaerPlaylistMerge.Snapshot()
        snap.lists["l1"] = .init(name: "Mix", updatedAt: 1_700_000_000,
                                 itemIds: ["jam:1", "lva:x"],
                                 titles: ["jam:1": "Sonata"],
                                 nameUpdatedAt: 1_700_000_100,
                                 snapshots: ["jam:1": CarriedItem(id: "jam:1", title: "Sonata", source: "jam")],
                                 removed: ["jam:9": 1_699_999_000],
                                 added: ["jam:1": 1_700_000_000],
                                 device: "phone")
        snap.tombstones["gone"] = 1_699_000_000
        return snap
    }

    @Test("der Schluessel-Traeger: eine Momentaufnahme reist in den Blob und zurueck, mit jedem Feld")
    func keyValueCarrierRoundTripsASnapshot() {
        let store = InMemoryCloudStore()
        let carrier = KeyValuePlaylistCarrier(store: store)
        #expect(carrier.name == "kvs")
        // Nothing there yet reads as an empty snapshot.
        #expect(carrier.held().lists.isEmpty && carrier.held().tombstones.isEmpty)

        carrier.store(sample)
        let back = carrier.held()
        #expect(back == sample, "every field survives the plist round trip")
        #expect(back.lists["l1"]?.device == "phone")
        #expect(back.lists["l1"]?.nameUpdatedAt == 1_700_000_100)
        #expect(back.tombstones["gone"] == 1_699_000_000)
    }

    @Test("ein Blob von vor den Feldern liest als Vereinigung, kein fehlendes Feld wirft")
    func aBlobFromBeforeTheFieldsStillReads() {
        let store = InMemoryCloudStore()
        // The oldest shape: name, updatedAt, items only.
        store.set(["old": ["name": "Alt", "updatedAt": 1_600_000_000.0, "items": ["lv:1"]]],
                  forKey: "maerPlaylists")
        let carrier = KeyValuePlaylistCarrier(store: store)
        let held = carrier.held()
        #expect(held.lists["old"]?.itemIds == ["lv:1"])
        #expect(held.lists["old"]?.titles.isEmpty == true)
        #expect(held.lists["old"]?.nameUpdatedAt == nil)
        #expect(held.lists["old"]?.removed.isEmpty == true)
    }

    @Test("der Start meldet genau einen Beobachter an, ein zweiter Start keinen weiteren")
    func startRegistersAtMostOneObserver() {
        let carrier = KeyValuePlaylistCarrier(store: InMemoryCloudStore())
        carrier.start { }
        carrier.start { }
        #expect(carrier.observerRegistrations == 1)
    }

    @Test("die Fabrik stellt die Playlisten auf den Dienst, sobald ein Zugang da ist, sonst auf den Schluessel")
    func theFactoryChoosesByAccess() {
        #expect(PlaylistCarriers.make(access: nil) is KeyValuePlaylistCarrier)
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        #expect(PlaylistCarriers.make(access: access) is MaerSyncPlaylistCarrier)
    }

    @Test("der Dienst-Traeger: die Momentaufnahme reist als EIN Dokument, eine fremde Fassung weckt den Laeufer")
    func serviceCarrierWritesOneWholeDocument() async throws {
        let name = "playlist-svc-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { "dev-a" }, defaults: defaults)
        let carrier = MaerSyncPlaylistCarrier(session: session)
        var woken = 0
        carrier.start { woken += 1 }

        carrier.store(sample)
        await session.refresh(by: "witness")
        let writes = transport.writes.filter { $0.kind == MaerSyncSession.playlistsKind }
        #expect(writes.map(\.scope) == [""], "one whole document, no per-device scope")
        #expect(writes.first?.declared == true, "playlists may shrink (a deletion), so the shrink is declared")
        let key = MaerSyncCarrierTests.FakeTransport.key(MaerSyncSession.playlistsKind, "")
        let stored = try #require(transport.documents[key])
        #expect(MaerSyncPlaylistWire.decode(stored.body) == sample)
        #expect(carrier.held() == sample)

        // Another device writes a different snapshot; the version moves, the
        // next round takes it and wakes the runner to re-merge.
        var other = MaerPlaylistMerge.Snapshot()
        other.lists["l2"] = .init(name: "Other", updatedAt: 1_700_000_500, itemIds: ["sub:song:9"])
        transport.foreignWrite(kind: MaerSyncSession.playlistsKind, scope: "",
                               body: try MaerSyncPlaylistWire.encode(other))
        await session.refresh(by: "tick")
        #expect(carrier.held() == other, "the far side is now the other device's snapshot")
        #expect(woken >= 1)

        // The claim and stats families are untouched by the playlists channel.
        #expect(session.claims.isEmpty)
    }

    @Test("der Draht traegt jedes Feld hin und zurueck; Unlesbares ist keine Momentaufnahme")
    func theServiceWireRoundTrips() throws {
        let data = try MaerSyncPlaylistWire.encode(sample)
        #expect(MaerSyncPlaylistWire.decode(data) == sample)
        #expect(MaerSyncPlaylistWire.decode(Data("nonsense".utf8)) == nil)
        // The same snapshot gives the same bytes, so a needless write is a
        // byte-for-byte match the runner skips.
        #expect(try MaerSyncPlaylistWire.encode(sample) == data)
    }
}
#endif
