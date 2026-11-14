// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Whether two snapshots are the same, every field of every list including
/// the device name. Only for round trips, where "every field survives" is
/// the claim; built on the production question `MaerPlaylistMerge.differs`,
/// so it compares the same fields, and the device name on top.
nonisolated func sameSnapshot(_ a: MaerPlaylistMerge.Snapshot?, _ b: MaerPlaylistMerge.Snapshot) -> Bool {
    guard let a, !MaerPlaylistMerge.differs(a, b) else { return false }
    return a.lists.allSatisfy { id, entry in b.lists[id].map { MaerPlaylistMerge.isSameVersion(entry, $0) } ?? false }
}

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

    @Test("the key carrier: a snapshot travels into the blob and back, with every field")
    func keyValueCarrierRoundTripsASnapshot() {
        let store = InMemoryCloudStore()
        let carrier = KeyValuePlaylistCarrier(store: store)
        #expect(carrier.name == "kvs")
        // Nothing there yet reads as an empty snapshot.
        #expect(carrier.held().lists.isEmpty && carrier.held().tombstones.isEmpty)

        carrier.store(sample)
        let back = carrier.held()
        #expect(sameSnapshot(back, sample), "every field survives the plist round trip")
        #expect(back.lists["l1"]?.device == "phone")
        #expect(back.lists["l1"]?.nameUpdatedAt == 1_700_000_100)
        #expect(back.tombstones["gone"] == 1_699_000_000)
    }

    @Test("a blob from before the fields reads as a union, no missing field throws")
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

    @Test("the start registers exactly one observer, a second start no further one")
    func startRegistersAtMostOneObserver() {
        let carrier = KeyValuePlaylistCarrier(store: InMemoryCloudStore())
        carrier.start { }
        carrier.start { }
        #expect(carrier.observerRegistrations == 1)
    }

    @Test("the factory puts the playlists on the service as soon as an access exists, otherwise on the key")
    func theFactoryChoosesByAccess() {
        #expect(PlaylistCarriers.make(access: nil) is KeyValuePlaylistCarrier)
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        #expect(PlaylistCarriers.make(access: access) is MaerSyncPlaylistCarrier)
    }

    @Test("the service carrier: the snapshot travels as ONE document, a foreign version wakes the runner")
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
        #expect(sameSnapshot(MaerSyncPlaylistWire.decode(stored.body), sample))
        #expect(sameSnapshot(carrier.held(), sample))

        // Another device writes a different snapshot; the version moves, the
        // next round takes it and wakes the runner to re-merge.
        var other = MaerPlaylistMerge.Snapshot()
        other.lists["l2"] = .init(name: "Other", updatedAt: 1_700_000_500, itemIds: ["sub:song:9"])
        transport.foreignWrite(kind: MaerSyncSession.playlistsKind, scope: "",
                               body: try MaerSyncPlaylistWire.encode(other))
        await session.refresh(by: "tick")
        #expect(sameSnapshot(carrier.held(), other), "the far side is now the other device's snapshot")
        #expect(woken >= 1)

        // The claim and stats families are untouched by the playlists channel.
        #expect(session.claims.isEmpty)
    }

    @Test("the CloudKit wire carries every field there and back, with and without a device")
    func theCloudKitWireRoundTrips() throws {
        let entry = try #require(sample.lists["l1"])
        let back = try #require(MaerPlaylistEntryWire.decode(MaerPlaylistEntryWire.encode(entry)))
        #expect(MaerPlaylistMerge.isSameVersion(back, entry) && back.device == "phone", "a field written is not read")
        var bare = entry
        bare.device = nil
        #expect(MaerPlaylistEntryWire.decode(MaerPlaylistEntryWire.encode(bare))?.device == nil)
        #expect(MaerPlaylistEntryWire.decode(Data("nonsense".utf8)) == nil)
    }

    @Test("one form for three wires: each wraps the same pair, each with its own device convention", .needsTheSources)
    func oneShapeForThreeWires() throws {
        // The pair itself: what it writes, it reads; an empty device reads as none.
        let entry = try #require(sample.lists["l1"])
        let roundTrip = try #require(KeyValuePlaylistCarrier.entry(from: KeyValuePlaylistCarrier.payload(of: entry, device: entry.device)))
        #expect(MaerPlaylistMerge.isSameVersion(roundTrip, entry) && roundTrip.device == "phone")
        #expect(KeyValuePlaylistCarrier.entry(from: KeyValuePlaylistCarrier.payload(of: entry, device: ""))?.device == nil)
        #expect(KeyValuePlaylistCarrier.payload(of: entry, device: nil)["device"] == nil)
        // Every wire wraps it, none spells the shape a second time, read over
        // all of the app's sources.
        var calls: [String: [Int]] = [:]
        var spelled: [String: Set<String>] = [:]
        for file in ProjectFileIntegrityTests.sourceTexts() {
            let code = SyncContractFenceTests.stripped(file.text)
            let pair = try Self.pairCalls(in: code, ownFile: file.name == "PlaylistCarrier.swift")
            if pair != [0, 0] { calls[file.name] = zip(calls[file.name] ?? [0, 0], pair).map(+) }
            for key in try Self.keysSpelled(in: code) { spelled[key, default: []].insert(file.name) }
        }
        #expect(calls == ["PlaylistCarrier.swift": [1, 1], "MaerSyncCarriers.swift": [1, 1],
                          "CloudKitPlaylistCarrier.swift": [1, 1]],
                "each of the three wires writes once and reads once through the pair: \(calls)")
        for key in Self.shapeKeys {
            let files = spelled[key] ?? []
            let others = files.subtracting(["PlaylistCarrier.swift"])
            #expect(files.contains("PlaylistCarrier.swift"), "the pair no longer spells \(key)")
            if Self.sharedWords[key] != nil {
                #expect(!others.isEmpty, "no other source uses \(key) any more, so it belongs to the list alone")
            } else {
                #expect(others.isEmpty, "\(others.sorted()) spell the list's \(key) again")
            }
        }
        // Calibration: a call from a fourth wire, a call inside the pair's own
        // type, the declarations (no call), a function of the same name on
        // another type, and a key in both spellings.
        #expect(try Self.pairCalls(in: "KeyValuePlaylistCarrier.payload(of: e, device: nil)", ownFile: false) == [1, 0])
        #expect(try Self.pairCalls(in: "if let e = Self.entry(from: v) {}", ownFile: true) == [0, 1])
        #expect(try Self.pairCalls(in: "x = payload(of: e, device: d)", ownFile: true) == [1, 0])
        #expect(try Self.pairCalls(in: "static func entry(from raw: Any?)\nstatic func payload(of e: E, device: String?)", ownFile: true) == [0, 0])
        #expect(try Self.pairCalls(in: "items.compactMap(entry(from:))", ownFile: false) == [0, 0])
        #expect(try Self.keysSpelled(in: "d[\"titles\"] = t; let p = [\"snapshots\": s]") == ["snapshots", "titles"])
    }

    /// The keys of a list on the key-value and record wires, as the pair
    /// writes them.
    nonisolated static let shapeKeys = ["added", "device", "items", "name", "nameUpdatedAt", "removed", "snapshots", "titles", "updatedAt"]

    /// Shape keys other sources also use for a field of their own, each with
    /// where. Every other key of the shape is spelled by the pair alone.
    static let sharedWords: [String: String] = [
        "device": "the device of a playback claim, a statistics record, a gpodder request and a sync service request",
        "name": "the device name of a playback claim, a Subsonic playlist request, a table name read from SQLite",
        "removed": "the removed address in the notice of known servers and its reader",
    ]

    /// How often a source writes and reads through the pair: [payload, entry].
    /// Outside the pair's own file only the qualified call counts, so a
    /// function of the same name on another type is not taken for it.
    nonisolated static func pairCalls(in code: String, ownFile: Bool) throws -> [Int] {
        let owner = ownFile ? #"(?:KeyValuePlaylistCarrier\.|Self\.|^|[^A-Za-z0-9_.])"# : #"KeyValuePlaylistCarrier\."#
        return try ["payload(of", "entry(from"].map { name in
            let found = code.matches(of: try Regex(owner + NSRegularExpression.escapedPattern(for: name))
                .anchorsMatchLineEndings()).count
            // In its own file the declaration reads like an unqualified call.
            return ownFile ? found - (code.components(separatedBy: "func \(name)").count - 1) : found
        }
    }

    /// The shape keys a source spells as a dictionary key, by subscript or
    /// in a literal.
    nonisolated static func keysSpelled(in code: String) throws -> Set<String> {
        Set(try Self.shapeKeys.filter { key in
            let literal = try Regex("\"\(key)\"\\s*:")
            return code.contains("[\"\(key)\"]") || code.contains(literal)
        })
    }

    @Test("the wire carries every field there and back; unreadable data is no snapshot")
    func theServiceWireRoundTrips() throws {
        let data = try MaerSyncPlaylistWire.encode(sample)
        #expect(sameSnapshot(MaerSyncPlaylistWire.decode(data), sample))
        #expect(MaerSyncPlaylistWire.decode(Data("nonsense".utf8)) == nil)
        // The same snapshot gives the same bytes, so a needless write is a
        // byte-for-byte match the runner skips.
        #expect(try MaerSyncPlaylistWire.encode(sample) == data)
    }
}
#endif
