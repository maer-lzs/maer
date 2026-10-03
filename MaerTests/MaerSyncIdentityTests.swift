// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A sign-in with another account on the sync service never writes one
/// account's data into the other and never replaces the new account's pot
/// with the old one's. The state of the session belongs to the identity
/// (the service's key and the account name), not to the device.
@MainActor
struct MaerSyncIdentityTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    typealias FakeAnnouncer = MaerSyncCarrierTests.FakeAnnouncer

    final class Box {
        var access: MaerSyncAccess?
        var identity: MaerSyncIdentity?
    }

    static let accessA = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "token-a")
    static let accessB = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "token-b")
    static let identityA = MaerSyncIdentity(service: "fp-service", owner: "anna")
    static let identityB = MaerSyncIdentity(service: "fp-service", owner: "bert")

    private struct Rig {
        let session: MaerSyncSession
        let transport: FakeTransport
        let box: Box
        let suite: String
    }

    private func rig() -> Rig {
        let suite = "maer-identity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let transport = FakeTransport()
        let box = Box()
        box.access = Self.accessA
        box.identity = Self.identityA
        let session = MaerSyncSession(transport: transport, announcer: FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity },
                                      deviceId: { "dev-a" }, defaults: defaults)
        return Rig(session: session, transport: transport, box: box, suite: suite)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    /// Signs in with B: the fake holds one pot per account, swapped here.
    private func switchTo(_ rig: Rig, identity: MaerSyncIdentity, access: MaerSyncAccess,
                          pots: inout [String: [String: FakeTransport.Stored]]) {
        if let current = rig.box.identity { pots[current.scope] = rig.transport.documents }
        rig.transport.documents = pots[identity.scope] ?? [:]
        rig.box.identity = identity
        rig.box.access = access
        rig.session.reloadAccess()
    }

    @Test("die Identitaet ist Dienst und Konto: andere Adresse, gleiche Identitaet; anderes Konto, andere")
    func theIdentityIsServiceAndAccount() {
        #expect(MaerSyncIdentity(service: "fp", owner: "anna").scope == MaerSyncIdentity(service: "fp", owner: "anna").scope)
        #expect(MaerSyncIdentity(service: "fp", owner: "anna").scope != MaerSyncIdentity(service: "fp", owner: "bert").scope)
        #expect(MaerSyncIdentity(service: "fp", owner: "anna").scope != MaerSyncIdentity(service: "fp2", owner: "anna").scope)
        #expect(Self.identityA.keyed("maerSyncStands") == "maerSyncStands.\(Self.identityA.scope)")
        #expect(!CarrierWay.identityChanged(held: nil, now: "x"), "the first sign-in is a change of way")
        #expect(!CarrierWay.identityChanged(held: "x", now: nil), "a sign-out is a change of way")
        #expect(CarrierWay.identityChanged(held: "x", now: "y"))
        #expect(CarrierWay.mustChange(holdsService: true, signedIn: true, identityChanged: true))
        #expect(!CarrierWay.mustChange(holdsService: true, signedIn: true, identityChanged: false))
    }

    /// Case 2 of the measurement: B's pot stood at the same version as A's,
    /// and A's mirror replaced it.
    @Test("Fall 2: B's Topf in gleicher Fassung wird nie durch A's Abbild ersetzt, A's Schlange bleibt bei A")
    func anEqualVersionNeverReplacesB() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        rig.transport.offline = true
        rig.session.enqueue(upserts: ["rss:a:3": [300, 3_000]], removing: ["rss:a:1"], by: "witness")
        await settle { rig.session.refreshSettled }
        rig.transport.offline = false

        pots[Self.identityB.scope] = [:]
        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        _ = rig.transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                                       body: try MaerSyncStandsWire.encode(["rss:x:9": [9, 9_999]]))
        try #require(rig.transport.documents.values.first?.version == 1, "B's pot stands at version 1 like A's did")
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(try rig.transport.stands() == ["rss:x:9": [9, 9_999]], "B keeps its own, nothing of A arrives")
        #expect(rig.session.stands["rss:x:9"] == [9, 9_999], "the device shows what B holds")
        #expect(rig.session.stands["rss:a:3"] == nil)
    }

    /// Case 1 of the measurement: B had no pot, and A's whole mirror became
    /// B's first document.
    @Test("Fall 1: ein leeres B bekommt nur, was unter B geschieht")
    func anEmptyBGetsOnlyWhatHappensUnderB() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000], "rss:a:2": [200, 2_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 2 }

        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        await rig.session.refresh(by: "witness")
        rig.session.enqueue(upserts: ["rss:b:1": [5, 9_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().isEmpty) == false && rig.session.refreshSettled }
        #expect(try rig.transport.stands() == ["rss:b:1": [5, 9_000]], "A's history stays out of B")
    }

    /// Right after the switch a runner may queue something before the first
    /// round ran: it waits until B is read, then goes out beside B's own.
    @Test("nach dem Wechsel wird nichts geschrieben, bevor B gelesen ist")
    func nothingIsWrittenBeforeBIsRead() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        pots[Self.identityB.scope] = [:]
        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        _ = rig.transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                                       body: try MaerSyncStandsWire.encode(["rss:x:9": [9, 9_999]]))
        let writes = rig.transport.writes.count
        rig.session.enqueue(upserts: ["rss:b:1": [5, 9_000]], removing: [], by: "witness")
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.transport.writes.count == writes, "a write went out before B was read")
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(try rig.transport.stands() == ["rss:x:9": [9, 9_999], "rss:b:1": [5, 9_000]],
                "after the read the write goes out beside B's own")
    }

    @Test("Rueckweg: wieder bei A ist A wie vorher, und A's ungesendete Schlange geht zu A")
    func backToAFindsAAsItWas() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        rig.transport.offline = true
        rig.session.enqueue(upserts: ["rss:a:2": [200, 2_000]], removing: [], by: "witness")
        await settle { rig.session.refreshSettled }
        rig.transport.offline = false

        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(try rig.transport.stands().isEmpty, "A's queue did not go to B")

        switchTo(rig, identity: Self.identityA, access: Self.accessA, pots: &pots)
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(try rig.transport.stands() == ["rss:a:1": [100, 1_000], "rss:a:2": [200, 2_000]],
                "A holds what it held, and what waited for A arrived")
    }

    @Test("Ruhe nach dem Wechsel: danach schreibt keine Runde")
    func quietAfterTheSwitch() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        let writes = rig.transport.writes.count
        for _ in 0..<3 { await rig.session.refresh(by: "tick") }
        await settle { rig.session.refreshSettled }
        #expect(rig.transport.writes.count == writes, "after the switch nobody writes")
    }

    /// The same account reached under another address (a LAN address, a
    /// name) is not a switch: nothing is reloaded, nothing waits.
    @Test("gleiche Identitaet unter anderer Adresse ist kein Wechsel")
    func theSameAccountElsewhereIsNoSwitch() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        rig.box.access = MaerSyncAccess(baseURL: URL(string: "https://192.168.1.5:8443")!, token: "token-a")
        rig.session.reloadAccess()
        #expect(rig.session.identity == Self.identityA)
        #expect(rig.session.stands["rss:a:1"] == [100, 1_000], "the state stayed")
        let writes = rig.transport.writes.count
        rig.session.enqueue(upserts: ["rss:a:2": [200, 2_000]], removing: [], by: "witness")
        await settle { rig.transport.writes.count > writes }
        #expect(rig.transport.writes.count > writes, "nothing waits for a read, it is the same account")
    }

    @Test("der Stand vor den Identitaeten gehoert der ersten Identitaet, einmal, und die schlichten Schluessel leeren sich")
    func thePlainStateGoesToTheFirstIdentity() {
        let suite = "maer-identity-plain-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set("7", forKey: MaerSyncSession.versionKey)
        MaerSyncSession.adoptPlainKeys(into: Self.identityA, defaults: defaults)
        #expect(defaults.string(forKey: Self.identityA.keyed(MaerSyncSession.versionKey)) == "7")
        #expect(defaults.object(forKey: MaerSyncSession.versionKey) == nil, "no later account inherits it")
        defaults.set("9", forKey: MaerSyncSession.versionKey)
        MaerSyncSession.adoptPlainKeys(into: Self.identityA, defaults: defaults)
        #expect(defaults.string(forKey: Self.identityA.keyed(MaerSyncSession.versionKey)) == "7", "once")
    }

    // MARK: - The runners and an answer on its way

    /// A runner that holds the service and records what it was told.
    final class RecordingFollower: AccessFollower {
        let followerName: String
        private(set) var changedCarrier = false
        private(set) var told: [(signedIn: Bool, identityChanged: Bool)] = []
        init(_ name: String) { followerName = name }
        func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
            told.append((signedIn, identityChanged))
            if CarrierWay.mustChange(holdsService: true, signedIn: signedIn, identityChanged: identityChanged) {
                changedCarrier = true
            }
        }
    }

    /// The first change of account in a process: the register asks the
    /// session, and it took the account its runners hold when they
    /// enrolled, not at its first use, when the new account was already
    /// stored and the change looked like none.
    @Test("der erste Kontowechsel des Prozesses erreicht jeden Laeufer")
    func theFirstSwitchOfAProcessReachesEveryRunner() async {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        let register = AccessRegister(identity: { rig.session.identity?.scope })
        let runners = [RecordingFollower("stands"), RecordingFollower("playlists"), RecordingFollower("claims")]
        for runner in runners { _ = register.enroll(runner) }

        var pots: [String: [String: FakeTransport.Stored]] = [:]
        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        register.followAll(by: "sign-in")
        for runner in runners {
            #expect(runner.told.map(\.identityChanged) == [true], "\(runner.followerName) was not told of the switch")
            #expect(runner.changedCarrier, "\(runner.followerName) kept the old account's carrier")
        }
        register.followAll(by: "sign-in")
        #expect(runners.allSatisfy { $0.told.last?.identityChanged == false }, "the same account again is no switch")
    }

    @Test("die Laeufer fragen nach dem Konto die Sitzung und keinen zweiten Speicher", .needsTheSources)
    func theRunnersAskTheSession() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/AccessFollowers.swift"), encoding: .utf8))
        #expect(!code.contains("MaerSyncIdentity.stored()"), "a second place answers which account is held")
        #expect(code.contains("MaerSyncCarriers.session.identity"))
    }

    /// A round asked A for its pot; the answer comes back after the switch
    /// to B, whose pot stands at the same version. Taken, it would become
    /// B's mirror and version, the read lock would fall, and the next write
    /// would land A's pot under B.
    @Test("eine Antwort, die vor dem Wechsel erfragt wurde, wirkt danach nicht")
    func anAnswerAskedBeforeTheSwitchDoesNothing() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.session.enqueue(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await settle { (try? rig.transport.stands().count) == 1 }
        await settle { rig.session.refreshSettled }
        var switched = false
        rig.transport.answerHeld = (MaerSyncSession.standsKind, { [self] in
            switched = true
            pots[Self.identityB.scope] = [:]
            switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
            _ = rig.transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                                           body: try! MaerSyncStandsWire.encode(["rss:x:9": [9, 9_999]]))
        })
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(switched, "the precondition: the answer came back after the switch")
        #expect(rig.session.stands["rss:a:1"] == nil, "A's pot became B's mirror")

        rig.session.enqueue(upserts: ["rss:b:1": [5, 9_000]], removing: [], by: "witness")
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(try rig.transport.stands() == ["rss:x:9": [9, 9_999], "rss:b:1": [5, 9_000]],
                "B keeps its own, nothing of A arrives")
    }
}
#endif
