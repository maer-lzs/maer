// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// A sync token that could not be read at start (before the first unlock
/// after a restart) is unknown: the families stay with the service, nothing
/// is kept without an identity, and a return reads it again.
@MainActor
struct MaerSyncUnknownAccessTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    typealias FakeAnnouncer = MaerSyncCarrierTests.FakeAnnouncer
    typealias RecordingFollower = MaerSyncIdentityTests.RecordingFollower

    final class Box {
        var access: MaerSyncAccess?
        var identity: MaerSyncIdentity?
        var unknown = true
    }

    static let accessA = MaerSyncIdentityTests.accessA
    static let identityA = MaerSyncIdentityTests.identityA

    @Test("an unreadable token is unknown, a missing one is no access")
    func anUnreadableTokenIsUnknown() {
        let url = "https://sync.example.test"
        #expect(MaerSyncAccessRead.of(url: url, token: .unreadable) == .unknown)
        #expect(MaerSyncAccessRead.of(url: url, token: .missing) == .absent)
        #expect(MaerSyncAccessRead.of(url: url, token: .value("")) == .absent)
        #expect(MaerSyncAccessRead.of(url: "", token: .unreadable) == .absent, "no address, no service")
        #expect(MaerSyncAccessRead.of(url: url, token: .value("t")).access?.token == "t")
        #expect(MaerSyncAccessRead.unknown.servesFamilies, "an unknown access sent the families to iCloud")
        #expect(!MaerSyncAccessRead.absent.servesFamilies)
    }

    @Test("with an unknown access no factory picks an iCloud or key-value carrier")
    func noFactoryPicksICloudOnAnUnknownAccess() {
        #expect(StandCarriers.make(read: .unknown) is MaerSyncStandCarrier)
        #expect(StatsCarriers.make(read: .unknown) is MaerSyncStatsCarrier)
        #expect(ClaimCarriers.make(read: .unknown) is MaerSyncClaimCarrier)
        #expect(ChoiceCarriers.make(read: .unknown) is MaerSyncChoiceCarrier)
        #expect(PlaylistCarriers.make(read: .unknown) is MaerSyncPlaylistCarrier)
        // No access at all stays today's way.
        #expect(ClaimCarriers.make(read: .absent) is KeyValueClaimCarrier)
        #expect(!(StandCarriers.make(read: .absent) is MaerSyncStandCarrier))
    }

    private func session(_ box: Box, defaults: UserDefaults, transport: FakeTransport) -> MaerSyncSession {
        MaerSyncSession(transport: transport, announcer: FakeAnnouncer(),
                        access: { box.access }, identity: { box.identity }, accessUnknown: { box.unknown },
                        deviceId: { "dev-a" }, defaults: defaults)
    }

    @Test("unknown, then readable: nothing stored without an identity, afterwards A's state as after a sign-in")
    func anUnknownAccessIsReadAgainLikeASignIn() throws {
        let suite = "maer-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        rows.set(Self.identityA.keyed(MaerSyncSession.mirrorKey), ["rss:a:1": [1, 1_000]])
        let transport = FakeTransport()
        let box = Box()
        let session = session(box, defaults: defaults, transport: transport)
        #expect(session.accessUnknown && session.access == nil && session.identity == nil)

        session.enqueue(upserts: ["rss:u:1": [5, 5_000]], removing: [], by: "witness")
        #expect(!rows.holds(MaerSyncSession.queueKey), "the unknown window wrote under keys without an identity")
        #expect(transport.documents.isEmpty, "a round ran without an access")
        #expect(!session.rereadIfUnknown(), "still locked: nothing changes")

        box.access = Self.accessA
        box.identity = Self.identityA
        box.unknown = false
        #expect(session.rereadIfUnknown())
        #expect(!session.accessUnknown && session.identity == Self.identityA && session.access == Self.accessA)
        #expect(session.stands["rss:a:1"] == [1, 1_000], "A's own state was not loaded")
        session.enqueue(upserts: ["rss:a:2": [2, 2_000]], removing: [], by: "witness")
        let queued = rows.rows(Self.identityA.keyed(MaerSyncSession.queueKey))
        #expect(queued["rss:a:2"] != nil, "the precondition: A's queue is written again")
        #expect(queued["rss:u:1"] == nil, "a write of the unknown window landed under A without being read first")
        #expect(!rows.holds(MaerSyncSession.queueKey))
        // The way back: neither the stands nor their version stand under the
        // names an older build reads.
        let old = defaults.dictionaryRepresentation().keys.filter {
            CarrierStandRows.isLegacyOwner($0) || $0.hasPrefix(CarrierStandRows.legacyScopedVersion + ".")
        }
        #expect(old.isEmpty, "an older build finds \(old.sorted())")
    }

    @Test("unknown, then missing: today's way without a service")
    func anUnknownAccessThatTurnsOutMissingLeavesTheService() throws {
        let suite = "maer-unknown-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = Box()
        let session = session(box, defaults: defaults, transport: FakeTransport())
        let register = AccessRegister(identity: { session.identity?.scope }, defaults: defaults)
        let runner = register.enroll(RecordingFollower("stands"))
        session.enqueue(upserts: ["rss:u:1": [5, 5_000]], removing: [], by: "witness")

        box.unknown = false
        #expect(session.rereadIfUnknown())
        #expect(session.access == nil && session.identity == nil)
        register.followAll(by: "access read", restart: true)
        #expect(runner.told.map(\.signedIn) == [false])
        #expect(runner.changedCarrier, "a runner kept the service without an access")
        session.enqueue(upserts: ["rss:u:2": [6, 6_000]], removing: [], by: "witness")
        #expect(CarrierStandRows.matching(defaults).rows(MaerSyncSession.queueKey)["rss:u:1"] == nil,
                "the unknown window's write was kept under keys without an identity")
    }

    @Test("became readable: every runner restarts and reads before it writes")
    func theRunnersStartAgainOnceTheAccessReads() {
        let suite = "maer-unknown-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope: String?
        let register = AccessRegister(identity: { scope }, defaults: defaults)
        let runner = register.enroll(RecordingFollower("stands"))
        scope = Self.identityA.scope
        register.followAll(by: "access read", restart: true)
        #expect(runner.told.map(\.identityChanged) == [true], "the runner kept what it held through the unknown window")
        register.followAll(by: "sign-in")
        #expect(runner.told.last?.identityChanged == false, "the same account again is no restart")
    }
}
