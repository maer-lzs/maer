// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The statistics travel through a carrier; the rule (sum on read, skip
/// the own mirror) does not. The key-value carrier keeps the old key per
/// device and the ceiling; the service carrier writes one document per
/// device with no ceiling; the factory chooses by the access, like the
/// pot's and the claim's. And the caps are the ceiling's, not the pot's.
@MainActor
struct StatsCarrierTests {
    private let pot = ListeningStatsData(secondsPerDay: ["2026-09-10": 600],
                                         secondsPerItem: ["radio:a": 500, "rss:show:ep": 100])

    @Test("der Schluessel-Traeger: ein Schluessel je Geraet, nur der eigene wird geschrieben, alle werden gelesen")
    func keyValueCarrierKeepsOneKeyPerDevice() throws {
        let store = InMemoryCloudStore()
        let carrier = KeyValueStatsCarrier(store: store)
        #expect(carrier.name == "kvs")
        #expect(carrier.hasRoomLimit, "one megabyte for everything")
        carrier.publish(pot, deviceId: "dev-a", by: "witness")
        #expect(store.dictionaryRepresentation.keys.sorted() == [ListeningStatsSync.key(forDeviceId: "dev-a")])
        // Another device's pot, written the way an older build writes it.
        let foreign = ListeningStatsData(secondsPerDay: ["2026-09-09": 60], secondsPerItem: [:])
        store.set(try JSONEncoder().encode(foreign), forKey: ListeningStatsSync.key(forDeviceId: "dev-b"))
        store.set(Data("nonsense".utf8), forKey: ListeningStatsSync.key(forDeviceId: "dev-broken"))
        let pots = carrier.pots()
        #expect(pots.keys.sorted() == ["dev-a", "dev-b"], "an unreadable pot counts as none")
        #expect(pots["dev-a"] == pot)
        #expect(pots["dev-b"] == foreign)
    }

    @Test("der Dienst-Traeger: ein Dokument je Geraet, fremde Toepfe ueber die Liste, kein Deckel")
    func serviceCarrierWritesOneDocumentPerDevice() async throws {
        let name = "stats-carrier-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { "dev-a" }, defaults: defaults)
        let carrier = MaerSyncStatsCarrier(session: session)
        #expect(!carrier.hasRoomLimit, "the service has no ceiling")
        var woken = 0
        carrier.start { woken += 1 }

        carrier.publish(pot, deviceId: "dev-a", by: "witness")
        await session.refresh(by: "witness")
        let writes = transport.writes.filter { $0.kind == MaerSyncSession.statsKind }
        #expect(writes.map(\.scope) == ["dev-a"])
        #expect(writes.first?.declared == false, "a pot only grows; a shrink there is a fault to show")
        let stored = try #require(transport.documents[MaerSyncCarrierTests.FakeTransport.key(MaerSyncSession.statsKind, "dev-a")])
        #expect(MaerSyncStatsWire.decode(stored.body) == pot)

        // Another device's pot appears in the listing and is fetched.
        let foreign = ListeningStatsData(secondsPerDay: ["2026-09-09": 60], secondsPerItem: ["rss:s:e": 7])
        transport.foreignWrite(kind: MaerSyncSession.statsKind, scope: "dev-b", body: try MaerSyncStatsWire.encode(foreign))
        await session.refresh(by: "tick")
        #expect(carrier.pots()["dev-b"] == foreign)
        #expect(carrier.pots()["dev-a"] == pot, "the own pot is held too; the rule skips it")
        #expect(woken >= 1)

        // The claim family is untouched by the stats family.
        #expect(session.claims.isEmpty)
    }

    @Test("die Fabrik stellt die Statistik auf den Dienst, sobald ein Zugang da ist, und sonst auf den Schluessel")
    func theFactoryChoosesByAccess() {
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        #expect(StatsCarriers.make(access: access) is MaerSyncStatsCarrier)
        #expect(StatsCarriers.make(access: nil) is KeyValueStatsCarrier)
    }

    @Test("der Topf reist als sein eigenes JSON mit sortierten Schluesseln; Unlesbares ist kein Topf")
    func theStatsWire() throws {
        let bytes = try MaerSyncStatsWire.encode(pot)
        #expect(try MaerSyncStatsWire.encode(pot) == bytes)
        #expect(MaerSyncStatsWire.decode(bytes) == pot)
        #expect(MaerSyncStatsWire.decode(Data("nonsense".utf8)) == nil)
        // A pot from a build before the item dimension still reads.
        #expect(MaerSyncStatsWire.decode(Data("{\"secondsPerDay\":{\"2026-01-01\":5}}".utf8))
                == ListeningStatsData(secondsPerDay: ["2026-01-01": 5], secondsPerItem: [:]))
    }

    @Test("die Kappen gehoeren dem Deckel: was reist und was bleibt, entscheidet der Traeger")
    func theCapsBelongToTheCeiling() {
        // On the key-value store only the live items travel and the item
        // pot is capped; the rules themselves are unchanged.
        let published = ListeningStatsSync.publishable(pot)
        #expect(published.secondsPerItem.keys.sorted() == ["radio:a"])
        var many: [String: Int] = [:]
        for index in 0..<600 { many["radio:\(index)"] = index }
        #expect(ListeningStatsSync.cappedItems(many, limit: ListeningStatsSync.itemPotCap).count == 500)
        // The cap sits where the pot is PUBLISHED, so the ceiling shapes
        // what travels and never the file (the store writes the pot whole).
        let capped = ListeningStatsSync.publishable(ListeningStatsData(secondsPerItem: many),
                                                    itemCap: ListeningStatsSync.itemPotCap)
        #expect(capped.secondsPerItem.count == 500, "publishing caps the live items")
        #expect(ListeningStatsSync.publishable(ListeningStatsData(secondsPerItem: many)).secondsPerItem.count == 600,
                "without a ceiling nothing is capped")
        // On a carrier with room the whole pot is what travels: nothing is
        // filtered, nothing capped. The store asks the carrier, not a
        // constant; the two carriers answer differently.
        #expect(KeyValueStatsCarrier(store: InMemoryCloudStore()).hasRoomLimit)
        let name = "stats-room-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(),
                                      announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { nil }, deviceId: { "dev-a" }, defaults: defaults)
        #expect(!MaerSyncStatsCarrier(session: session).hasRoomLimit)
    }
}
#endif
