// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// Carrying an identity's state over to one that already holds state (a
/// device restored from a backup: the fingerprint holds the backup's
/// state) loses nothing that has not gone out: the queues join, the newer
/// moment winning per title; the picture of what the service holds is the
/// source's whole when it has read, never mixed per entry; the removals are
/// the source's alone (they carry no moment, and an old one would delete a
/// title made again elsewhere); a pending document of the target that has
/// to give way is said in the log.
@MainActor
struct IdentityCarryTests {
    typealias Side = IdentityCarry.Side

    static let backup = Side(stands: ["rss:b:1": [1, 1_000], "rss:gone:1": [9, 900]], standsVersion: "v-backup",
                             queue: ["rss:b:2": [2, 2_000], "rss:both:1": [3, 3_000]], removals: ["rss:old:1"],
                             playlistsPending: Data("backup-lists".utf8), choicesPending: nil)
    static let window = Side(stands: ["rss:b:1": [5, 5_000]], standsVersion: "v-now",
                             queue: ["rss:w:1": [4, 4_000], "rss:both:1": [6, 6_000]], removals: ["rss:new:1"],
                             playlistsPending: Data("window-lists".utf8), choicesPending: nil)

    @Test("the queues join; on the same title the newer moment wins")
    func queuesJoin() {
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup, living: .source)
        #expect(carried.side.queue == ["rss:b:2": [2, 2_000], "rss:w:1": [4, 4_000], "rss:both:1": [6, 6_000]])
    }

    @Test("the picture is the source's whole when it has read, the target's whole when it has not; never mixed")
    func pictureWhole() {
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup, living: .source)
        #expect(carried.side.stands == ["rss:b:1": [5, 5_000]], "a title the service no longer holds came back from the backup")
        #expect(carried.side.standsVersion == "v-now")
        var unread = Self.window
        unread.standsVersion = nil
        unread.stands = [:]
        let kept = IdentityCarry.merged(source: unread, target: Self.backup, living: .target)
        #expect(kept.side.stands == Self.backup.stands && kept.side.standsVersion == "v-backup")
    }

    @Test("the removals are the source's alone")
    func removals() {
        #expect(IdentityCarry.merged(source: Self.window, target: Self.backup, living: .source).side.removals == ["rss:new:1"])
    }

    @Test("pending documents: the source's when it has one, else the target's; a target's that gives way is named")
    func pendingDocuments() {
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup, living: .source)
        #expect(carried.side.playlistsPending == Data("window-lists".utf8))
        #expect(carried.dropped.contains("playlists"), "the target's pending document fell without a word")
        var none = Self.window
        none.playlistsPending = nil
        let kept = IdentityCarry.merged(source: none, target: Self.backup, living: .source)
        #expect(kept.side.playlistsPending == Data("backup-lists".utf8) && !kept.dropped.contains("playlists"))
    }

    @Test("an empty target takes the source as it is")
    func emptyTarget() {
        let carried = IdentityCarry.merged(source: Self.window, target: Side(), living: .source)
        #expect(carried.side == Self.window && carried.dropped.isEmpty)
    }

    @Test("the session carries onto a target with the backup's queue without losing it")
    func sessionKeepsTheBackupQueue() throws {
        let suite = "maer-carry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let byKey = ServiceKeyIdentityTests.byKey
        let byAddress = ServiceKeyIdentityTests.byAddress
        rows.set(byKey.keyed(MaerSyncSession.queueKey), ["rss:b:2": [2, 2_000]])
        let box = ServiceKeyIdentityTests.Box()
        box.access = ServiceKeyIdentityTests.access
        box.identity = byAddress
        let session = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(), announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                                      deviceId: { "dev-a" }, defaults: defaults)
        session.enqueue(upserts: ["rss:w:1": [4, 4_000]], removing: [], by: "witness")
        box.identity = byKey
        session.reloadAccess()
        let queue = rows.rows(byKey.keyed(MaerSyncSession.queueKey))
        #expect(queue["rss:b:2"] == [2, 2_000], "the backup's queue was lost")
        #expect(queue["rss:w:1"] == [4, 4_000])
    }

    // MARK: Which side lives

    @Test("where nobody knows, the newest moment over picture and queue tells which side lives; equal moments are a tie")
    func livingByMoment() {
        let old = Side(stands: ["rss:x:1": [1, 1_000]], standsVersion: "v-old")
        let new = Side(stands: ["rss:x:1": [2, 9_000]], standsVersion: "v-new")
        #expect(IdentityCarry.living(source: old, target: new) == .target)
        #expect(IdentityCarry.living(source: new, target: old) == .source)
        #expect(IdentityCarry.living(source: Side(queue: ["rss:q:1": [1, 9_000]]), target: old) == .source, "the queue counts")
        #expect(IdentityCarry.living(source: old, target: Side()) == .source, "an empty side does not live")
        #expect(IdentityCarry.living(source: old, target: old) == .tie)
    }

    @Test("cold start, the address old and the fingerprint living: everything of the target stays, the old queue joins by moment, what falls is named")
    func coldStartLivingTarget() {
        let address = Side(stands: ["rss:gone:1": [1, 1_000]], standsVersion: "v-old", queue: ["rss:q:1": [3, 3_000], "rss:both:1": [1, 1_500]],
                           removals: ["rss:old:1"], playlistsPending: Data("old".utf8))
        let fingerprint = Side(stands: ["rss:live:1": [5, 8_000]], standsVersion: "v-live", queue: ["rss:both:1": [7, 7_000]],
                               removals: ["rss:new:1"], playlistsPending: Data("live".utf8))
        let carried = IdentityCarry.merged(source: address, target: fingerprint, living: .target)
        #expect(carried.side.stands == fingerprint.stands && carried.side.standsVersion == "v-live")
        #expect(carried.side.removals == ["rss:new:1"])
        #expect(carried.side.playlistsPending == Data("live".utf8))
        #expect(carried.side.queue == ["rss:q:1": [3, 3_000], "rss:both:1": [7, 7_000]])
        #expect(Set(carried.dropped) == ["removals", "playlists"])
    }

    @Test("a tie at a cold start: the target keeps picture, version and pending documents, and the removals of neither side apply")
    func tieAtColdStart() {
        let a = Side(stands: ["rss:x:1": [1, 1_000]], standsVersion: "v-a", removals: ["rss:a:1"], playlistsPending: Data("a".utf8))
        let b = Side(stands: ["rss:x:1": [1, 1_000]], standsVersion: "v-b", removals: ["rss:b:1"], playlistsPending: Data("b".utf8))
        let carried = IdentityCarry.merged(source: a, target: b, living: .tie)
        #expect(carried.side.standsVersion == "v-b" && carried.side.playlistsPending == Data("b".utf8))
        #expect(carried.side.removals.isEmpty, "an old removal applied deletes a title; a fallen one lets it come back")
        #expect(carried.dropped.contains("removals"))
    }

    @Test("at a reload the caller knows the source lives, even when the backup holds a younger entry")
    func reloadKnowsTheSourceLives() {
        var backup = Self.backup
        backup.queue["rss:young:1"] = [1, 99_000]
        let carried = IdentityCarry.merged(source: Self.window, target: backup, living: .source)
        #expect(carried.side.stands == Self.window.stands && carried.side.removals == Self.window.removals)
        #expect(carried.side.queue["rss:young:1"] == [1, 99_000], "the backup's queue still joins")
    }

    @Test("after carrying onto a target with state, the session reads the service before it writes")
    func readsBeforeWriting() throws {
        let suite = "maer-carry-read-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let byKey = ServiceKeyIdentityTests.byKey
        let byAddress = ServiceKeyIdentityTests.byAddress
        rows.set(byAddress.keyed(MaerSyncSession.queueKey), ["rss:w:1": [4, 4_000]])
        rows.set(byKey.keyed(MaerSyncSession.mirrorKey), ["rss:b:1": [2, 2_000]])
        let box = ServiceKeyIdentityTests.Box()
        box.access = ServiceKeyIdentityTests.access
        box.identity = byKey
        let session = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(), announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                                      deviceId: { "dev-a" }, defaults: defaults)
        #expect(session.waitsForRead, "the carry onto a target with state writes before reading the service")
    }

    @Test("cold start, the target living: the documents' pictures and versions of the target stay, the address's old ones do not replace them")
    func documentPicturesFollowLiving() throws {
        let suite = "maer-carry-docs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let documents = CarrierDocumentRows.matching(defaults)
        let from = ServiceKeyIdentityTests.byAddress
        let to = ServiceKeyIdentityTests.byKey
        documents.setBody(from.keyed(MaerSyncSession.playlistsMirrorKey), Data("old".utf8))
        defaults.set("v-old", forKey: from.keyed(MaerSyncSession.playlistsVersionKey))
        documents.setBody(to.keyed(MaerSyncSession.playlistsMirrorKey), Data("live".utf8))
        defaults.set("v-live", forKey: to.keyed(MaerSyncSession.playlistsVersionKey))
        MaerSyncSession.carryRows(from: from, to: to, living: .target, defaults: defaults, rows: rows, documents: documents)
        #expect(documents.body(to.keyed(MaerSyncSession.playlistsMirrorKey)) == Data("live".utf8), "the old picture replaced the living one")
        #expect(defaults.string(forKey: to.keyed(MaerSyncSession.playlistsVersionKey)) == "v-live")
    }

    @Test("a target holding only removals, only a document's picture or only a version counts as holding state")
    func targetHeldCountsEveryKey() throws {
        let from = ServiceKeyIdentityTests.byAddress
        let to = ServiceKeyIdentityTests.byKey
        let fills: [(String, (UserDefaults, CarrierDocumentRows) -> Void)] = [
            ("removals", { d, _ in StandMirrorStore.saveList(["rss:r:1"], key: to.keyed(MaerSyncSession.removalsKey), defaults: d) }),
            ("choices picture", { _, docs in docs.setBody(to.keyed(MaerSyncSession.choicesMirrorKey), Data("c".utf8)) }),
            ("playlists version", { d, _ in d.set("v", forKey: to.keyed(MaerSyncSession.playlistsVersionKey)) }),
        ]
        for (name, fill) in fills {
            let suite = "maer-carry-held-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let rows = CarrierStandRows.matching(defaults)
            let documents = CarrierDocumentRows.matching(defaults)
            rows.set(from.keyed(MaerSyncSession.queueKey), ["rss:w:1": [1, 1_000]])
            fill(defaults, documents)
            #expect(MaerSyncSession.carryRows(from: from, to: to, living: .source, defaults: defaults, rows: rows, documents: documents),
                    "a target with only \(name) counted as empty")
        }
    }

    @Test("after carrying onto a target with state no stands write goes out before the stands were read")
    func noWriteBeforeRead() async throws {
        let suite = "maer-carry-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let byKey = ServiceKeyIdentityTests.byKey
        rows.set(ServiceKeyIdentityTests.byAddress.keyed(MaerSyncSession.queueKey), ["rss:w:1": [4, 4_000]])
        rows.set(byKey.keyed(MaerSyncSession.mirrorKey), ["rss:b:1": [2, 2_000]])
        let box = ServiceKeyIdentityTests.Box()
        box.access = ServiceKeyIdentityTests.access
        box.identity = byKey
        let transport = MaerSyncCarrierTests.FakeTransport()
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                                      deviceId: { "dev-a" }, defaults: defaults)
        session.enqueue(upserts: ["rss:n:1": [5, 5_000]], removing: [], by: "witness")
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        let wroteStands = transport.writes.contains { $0.kind == MaerSyncSession.standsKind }
        #expect(!wroteStands || transport.fetches.contains(MaerSyncSession.standsKind),
                "a stands write went out before the stands were read")
    }

    @Test("a cold start takes over a state under the address that holds only removals or only a document")
    func coldStartTakesEveryKey() throws {
        let fills: [(String, (UserDefaults, CarrierDocumentRows) -> Void)] = [
            ("removals", { d, _ in StandMirrorStore.saveList(["rss:r:1"], key: ServiceKeyIdentityTests.byAddress.keyed(MaerSyncSession.removalsKey), defaults: d) }),
            ("a pending document", { _, docs in docs.setBody(ServiceKeyIdentityTests.byAddress.keyed(MaerSyncSession.identityDocuments[0]), Data("p".utf8)) }),
        ]
        for (name, fill) in fills {
            let suite = "maer-carry-cold-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let documents = CarrierDocumentRows.matching(defaults)
            fill(defaults, documents)
            let box = ServiceKeyIdentityTests.Box()
            box.access = ServiceKeyIdentityTests.access
            box.identity = ServiceKeyIdentityTests.byKey
            _ = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(), announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                                deviceId: { "dev-a" }, defaults: defaults)
            #expect(!MaerSyncSession.holdsState(ServiceKeyIdentityTests.byAddress, defaults: defaults,
                                                rows: CarrierStandRows.matching(defaults), documents: documents),
                    "a state under the address with only \(name) stayed behind")
        }
    }

    @Test("Fence G-39-37-b: every key of the three lists stands at the target after the carry")
    func everyListedKeyCarries() throws {
        let suite = "maer-carry-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let documents = CarrierDocumentRows.matching(defaults)
        let from = ServiceKeyIdentityTests.byAddress
        let to = ServiceKeyIdentityTests.byKey
        for key in MaerSyncSession.identityKeys {
            if key == MaerSyncSession.removalsKey {
                StandMirrorStore.saveList(["rss:r:1"], key: from.keyed(key), defaults: defaults)
            } else {
                defaults.set("v-\(key)", forKey: from.keyed(key))
            }
        }
        for owner in MaerSyncSession.identityOwners { rows.set(from.keyed(owner), ["rss:\(owner):1": [1, 1_000]]) }
        for owner in MaerSyncSession.identityDocuments { documents.setBody(from.keyed(owner), Data(owner.utf8)) }
        MaerSyncSession.carryRows(from: from, to: to, living: .source, defaults: defaults, rows: rows, documents: documents)
        for key in MaerSyncSession.identityKeys {
            #expect(defaults.object(forKey: to.keyed(key)) != nil, "\(key) was cleared without being carried")
        }
        for owner in MaerSyncSession.identityOwners { #expect(rows.holds(to.keyed(owner)), "\(owner)") }
        for owner in MaerSyncSession.identityDocuments { #expect(documents.body(to.keyed(owner)) != nil, "\(owner)") }
    }

    @Test("a cold start with the pin readable takes over a state stranded under the address (a device from before pins, or one ended in the window)")
    func coldStartCarries() throws {
        let suite = "maer-carry-cold-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        let byKey = ServiceKeyIdentityTests.byKey
        let byAddress = ServiceKeyIdentityTests.byAddress
        rows.set(byAddress.keyed(MaerSyncSession.queueKey), ["rss:w:1": [4, 4_000]])
        rows.set(byKey.keyed(MaerSyncSession.queueKey), ["rss:b:2": [2, 2_000]])
        let box = ServiceKeyIdentityTests.Box()
        box.access = ServiceKeyIdentityTests.access
        box.identity = byKey
        let session = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(), announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                                      deviceId: { "dev-a" }, defaults: defaults)
        #expect(session.identity == byKey)
        let queue = rows.rows(byKey.keyed(MaerSyncSession.queueKey))
        #expect(queue["rss:w:1"] == [4, 4_000], "the state under the address stayed stranded")
        #expect(queue["rss:b:2"] == [2, 2_000])
        #expect(!rows.holds(byAddress.keyed(MaerSyncSession.queueKey)))
    }

    @Test("Fence: the carry asks the rule, also for an accepted changed key", .needsTheSources)
    func carryAsksTheRule() throws {
        let carriers = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        let carry = carriers.components(separatedBy: "func carryIdentity(to next: MaerSyncIdentity) {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        #expect(carry.contains("Self.carryRows(from: current, to: next,"), "the carry lays the source over the target")
        let rule = carriers.components(separatedBy: "static func carryRows(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        #expect(rule.contains("IdentityCarry.merged("))
        #expect(!rule.contains("rename(owner:") && !carry.contains("rename(owner:"), "the rows are still renamed over the target")
        #expect(carriers.components(separatedBy: "Self.carryRows(").count - 1 == 2, "the reload and the cold start carry by the one rule")
    }

    @Test("two pending documents are joined by the given rule; without one the living side's stays and the other is named")
    func pendingJoined() {
        var source = IdentityCarry.Side(); source.playlistsPending = Data("A".utf8); source.choicesPending = Data("c".utf8)
        var target = IdentityCarry.Side(); target.playlistsPending = Data("B".utf8); target.choicesPending = Data("d".utf8)
        let joined = IdentityCarry.merged(source: source, target: target, living: .source,
                                          mergePending: { _, live, other in live + other })
        #expect(joined.side.playlistsPending == Data("AB".utf8))
        #expect(joined.side.choicesPending == Data("cd".utf8))
        #expect(joined.dropped.isEmpty, "a joined document is named as fallen")
        let unjoined = IdentityCarry.merged(source: source, target: target, living: .source,
                                            mergePending: { _, _, _ in nil })
        #expect(unjoined.side.playlistsPending == Data("A".utf8))
        #expect(unjoined.dropped.contains("playlists"))
    }

    @Test("the playlists of both pending documents stand after the carry, by the merge of the service")
    func playlistsJoined() throws {
        func body(_ id: String, _ name: String) throws -> Data {
            try MaerSyncPlaylistWire.encode(MaerPlaylistMerge.Snapshot(lists: [id: MaerPlaylistMerge.Entry(
                name: name, updatedAt: 10, itemIds: ["x"])]))
        }
        let joined = try #require(MaerSyncSession.mergedPending(kind: MaerSyncSession.playlistsKind,
                                                                 live: try body("one", "One"), other: try body("two", "Two")))
        let lists = try #require(MaerSyncPlaylistWire.decode(joined)).lists
        #expect(Set(lists.keys) == ["one", "two"])
    }

    @Test("the choices of both pending documents stand after the carry, the newer stamp winning per key")
    func choicesJoined() throws {
        func body(_ entries: [String: Double]) throws -> Data {
            try MaerSyncChoiceWire.encode(entries.mapValues { ["t": $0] as [String: Any] })
        }
        let joined = try #require(MaerSyncSession.mergedPending(kind: MaerSyncSession.choicesKind,
                                                                 live: try body(["a": 5, "shared": 1]),
                                                                 other: try body(["b": 6, "shared": 9])))
        let blob = try #require(MaerSyncChoiceWire.decode(joined))
        #expect(Set(blob.keys) == ["a", "b", "shared"])
        #expect(((blob["shared"] as? [String: Any])?["t"] as? Double) == 9)
    }
}
