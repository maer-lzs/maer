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
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup)
        #expect(carried.side.queue == ["rss:b:2": [2, 2_000], "rss:w:1": [4, 4_000], "rss:both:1": [6, 6_000]])
    }

    @Test("the picture is the source's whole when it has read, the target's whole when it has not; never mixed")
    func pictureWhole() {
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup)
        #expect(carried.side.stands == ["rss:b:1": [5, 5_000]], "a title the service no longer holds came back from the backup")
        #expect(carried.side.standsVersion == "v-now")
        var unread = Self.window
        unread.standsVersion = nil
        unread.stands = [:]
        let kept = IdentityCarry.merged(source: unread, target: Self.backup)
        #expect(kept.side.stands == Self.backup.stands && kept.side.standsVersion == "v-backup")
    }

    @Test("the removals are the source's alone")
    func removals() {
        #expect(IdentityCarry.merged(source: Self.window, target: Self.backup).side.removals == ["rss:new:1"])
    }

    @Test("pending documents: the source's when it has one, else the target's; a target's that gives way is named")
    func pendingDocuments() {
        let carried = IdentityCarry.merged(source: Self.window, target: Self.backup)
        #expect(carried.side.playlistsPending == Data("window-lists".utf8))
        #expect(carried.dropped == ["playlists"], "the target's pending document fell without a word")
        var none = Self.window
        none.playlistsPending = nil
        let kept = IdentityCarry.merged(source: none, target: Self.backup)
        #expect(kept.side.playlistsPending == Data("backup-lists".utf8) && kept.dropped.isEmpty)
    }

    @Test("an empty target takes the source as it is")
    func emptyTarget() {
        let carried = IdentityCarry.merged(source: Self.window, target: Side())
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
}
