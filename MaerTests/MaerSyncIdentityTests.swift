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
        #expect(StockOwner.change(owner: nil, now: "x") == .first("x"), "the first sign-in takes the stock over")
        #expect(StockOwner.change(owner: "x", now: nil) == .none, "a sign-out keeps the owner")
        #expect(StockOwner.change(owner: "x", now: "x") == .none)
        #expect(StockOwner.change(owner: "x", now: "y") == .switched(from: "x", to: "y"))
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

    /// The witness of the decision of 03.10.: what waited for A arrives at
    /// A on the way back, for the playlists and the choices too, whose
    /// body the mirror held before the service took it.
    @Test("Rueckweg: ein ungesendeter Playlisten- und Wahlen-Koerper von A geht zu A, nie zu B")
    func aBodyThatWaitedForAReachesA() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        let lists = Data("lists of anna".utf8)
        let choices = Data("choices of anna".utf8)
        rig.transport.offline = true
        rig.session.writePlaylists(lists, by: "witness")
        rig.session.writeChoices(choices, by: "witness")
        await settle { rig.session.refreshSettled }
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        rig.transport.offline = false
        let playlists = FakeTransport.key(MaerSyncSession.playlistsKind, "")
        let choiceKey = FakeTransport.key(MaerSyncSession.choicesKind, "")
        #expect(rig.transport.documents[playlists] == nil, "the precondition: nothing reached A yet")

        switchTo(rig, identity: Self.identityB, access: Self.accessB, pots: &pots)
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(rig.transport.documents[playlists] == nil && rig.transport.documents[choiceKey] == nil,
                "A's bodies went to B")

        switchTo(rig, identity: Self.identityA, access: Self.accessA, pots: &pots)
        await rig.session.refresh(by: "witness")
        await settle { rig.session.refreshSettled }
        #expect(rig.transport.documents[playlists]?.body == lists, "A's playlists never reached A")
        #expect(rig.transport.documents[choiceKey]?.body == choices, "A's choices never reached A")
    }

    @Test("ein ungesendeter Koerper ueberlebt den Neustart und geht danach hinaus")
    func aWaitingBodySurvivesARestart() async throws {
        let suite = "maer-identity-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let transport = FakeTransport()
        let box = Box()
        box.access = Self.accessA
        box.identity = Self.identityA
        func session() -> MaerSyncSession {
            MaerSyncSession(transport: transport, announcer: FakeAnnouncer(),
                            access: { box.access }, identity: { box.identity },
                            deviceId: { "dev-a" }, defaults: UserDefaults(suiteName: suite)!)
        }
        let first = session()
        transport.offline = true
        first.writePlaylists(Data("lists".utf8), by: "witness")
        // The first session's own attempt ends offline before the restart,
        // so only the kept body can bring the lists to the service.
        await first.refresh(by: "witness")
        await settle { first.refreshSettled }
        let attempts = transport.writes.count
        transport.offline = false

        #expect(transport.writes.count == attempts, "the first session wrote after the restart")
        let second = session()
        await second.refresh(by: "witness")
        await settle { second.refreshSettled }
        #expect(transport.documents[FakeTransport.key(MaerSyncSession.playlistsKind, "")]?.body == Data("lists".utf8),
                "a body written before the restart never went out")
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
        let rows = CarrierStandRows.matching(defaults)
        defaults.set("7", forKey: MaerSyncSession.versionKey)
        rows.set(MaerSyncSession.mirrorKey, ["rss:p:1": [1, 1_000]])
        MaerSyncSession.adoptPlainKeys(into: Self.identityA, defaults: defaults, rows: rows)
        #expect(defaults.string(forKey: Self.identityA.keyed(MaerSyncSession.versionKey)) == "7")
        #expect(defaults.object(forKey: MaerSyncSession.versionKey) == nil, "no later account inherits it")
        #expect(rows.rows(Self.identityA.keyed(MaerSyncSession.mirrorKey)) == ["rss:p:1": [1, 1_000]], "the stands stayed plain")
        #expect(!rows.holds(MaerSyncSession.mirrorKey), "no later account inherits the stands")
        defaults.set("9", forKey: MaerSyncSession.versionKey)
        MaerSyncSession.adoptPlainKeys(into: Self.identityA, defaults: defaults, rows: rows)
        #expect(defaults.string(forKey: Self.identityA.keyed(MaerSyncSession.versionKey)) == "7", "once")
    }

    // MARK: - The runners and an answer on its way

    /// A runner that holds the service and records what it was told.
    final class RecordingFollower: AccessFollower {
        let followerName: String
        private(set) var changedCarrier = false
        private(set) var told: [(signedIn: Bool, identityChanged: Bool)] = []
        /// The owner before, each time the stock was asked to follow.
        private(set) var owners: [String?] = []
        /// The order of the two questions, for the witness of the order.
        private(set) var calls: [String] = []
        init(_ name: String) { followerName = name }
        func followOwner(previous: String?) {
            owners.append(previous)
            calls.append("owner")
        }
        func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
            told.append((signedIn, identityChanged))
            calls.append("access")
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
        let register = AccessRegister(identity: { rig.session.identity?.scope },
                                      defaults: UserDefaults(suiteName: rig.suite)!)
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

    /// A, signed out, then B: the stock is A's, and B is another account.
    /// The register held only the last account seen and lost it at the
    /// sign-out, so B looked like a first sign-in.
    @Test("A, abgemeldet, dann B ist ein Kontowechsel; A, abgemeldet, dann A keiner; auch ueber einen Neustart")
    func aSwitchCountsAcrossASignOutAndARestart() {
        let suite = "maer-owner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope: String? = Self.identityA.scope
        let register = AccessRegister(identity: { scope }, defaults: defaults)
        let runner = register.enroll(RecordingFollower("stands"))
        #expect(StockOwner.owner(in: defaults) == Self.identityA.scope, "a signed-in device owns its stock")

        scope = nil
        register.followAll(by: "sign-out")
        #expect(runner.told.last?.identityChanged == false && runner.told.last?.signedIn == false)
        scope = Self.identityA.scope
        register.followAll(by: "sign-in")
        #expect(runner.told.last?.identityChanged == false, "A again after a sign-out is no switch")

        scope = nil
        register.followAll(by: "sign-out")
        // A restart while signed out: a new register on the same device.
        let restarted = AccessRegister(identity: { scope }, defaults: defaults)
        let fresh = restarted.enroll(RecordingFollower("stands"))
        scope = Self.identityB.scope
        restarted.followAll(by: "sign-in")
        #expect(fresh.told.last?.identityChanged == true, "B after A and a sign-out passed as a first sign-in")
        #expect(StockOwner.owner(in: defaults) == Self.identityB.scope)
    }

    @Test("ein Kontowechsel uebergibt jeden Bestand mit dem Eigentuemer davor, vor dem Neustart der Traeger und ohne den Sync-Schalter zu fragen; abgemeldet nichts")
    func aSwitchHandsTheStockOverWithTheOwnerBefore() {
        let suite = "maer-owner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let wasSync = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let wasSync { UserDefaults.standard.set(wasSync, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        var scope: String? = Self.identityA.scope
        let register = AccessRegister(identity: { scope }, defaults: defaults)
        let runner = register.enroll(RecordingFollower("playlists"))
        scope = nil
        register.followAll(by: "sign-out")
        #expect(runner.owners.isEmpty, "a sign-out handed a stock over")
        scope = Self.identityB.scope
        register.followAll(by: "sign-in")
        #expect(runner.owners == [Self.identityA.scope], "the switch to B did not hand A's stock over: \(runner.owners)")
        #expect(runner.calls.suffix(2) == ["owner", "access"], "the carrier started before the stock followed")
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

    /// The switch closes A's line, but what was on its way still comes: an
    /// announcement of A's account would fetch A's document under B.
    @Test("eine Ansage der Leitung von A, die nach dem Wechsel eintrifft, holt nichts; die Leitung von B holt")
    func anAnnouncementOfTheOldLineDoesNothing() async throws {
        let suite = "maer-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let box = Box()
        box.access = Self.accessA
        box.identity = Self.identityA
        let session = MaerSyncSession(transport: transport, announcer: announcer,
                                      access: { box.access }, identity: { box.identity },
                                      deviceId: { "dev-a" }, defaults: defaults)
        await session.refresh(by: "witness")
        await settle { session.refreshSettled }
        let lineOfA = try #require(announcer.onAnnouncement, "the precondition: A's line stood")

        box.identity = Self.identityB
        box.access = Self.accessB
        session.reloadAccess()
        await session.refresh(by: "witness")
        await settle { session.refreshSettled }
        let before = transport.fetches.count
        lineOfA(MaerSyncAnnouncement(kind: MaerSyncSession.playlistsKind, scope: "", version: "99"))
        await settle { false }
        #expect(transport.fetches.count == before, "an announcement of A's line fetched for B")

        announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.playlistsKind, scope: "", version: "99"))
        await settle { transport.fetches.count > before }
        #expect(transport.fetches.count > before, "the control: an announcement of B's line fetches")
    }

    /// The line's history (failed opens, the last try, the paths that
    /// failed) belongs to the account it was opened for: B does not wait
    /// out A's failures.
    @Test("ein Kontowechsel faengt die Geschichte der Leitung neu an, B wartet nicht auf die Fehlschlaege von A")
    func aNewAccountDoesNotWaitOutTheOldLine() async throws {
        let suite = "maer-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        announcer.failOpens = true
        let box = Box()
        box.access = Self.accessA
        box.identity = Self.identityA
        let session = MaerSyncSession(transport: transport, announcer: announcer,
                                      access: { box.access }, identity: { box.identity },
                                      deviceId: { "dev-a" }, defaults: defaults)
        await session.refresh(by: "witness")
        await settle { session.refreshSettled }
        #expect(session.openFailures >= 1, "the precondition: A's line never stood")
        let opensAsA = announcer.opens
        await session.refresh(by: "witness")
        await settle { session.refreshSettled }
        #expect(announcer.opens == opensAsA, "the precondition: A waits after its failure")

        box.identity = Self.identityB
        box.access = Self.accessB
        session.reloadAccess()
        #expect(session.openFailures == 0, "B starts with A's failures")
        await session.refresh(by: "witness")
        await settle { session.refreshSettled }
        #expect(announcer.opens > opensAsA, "B waited out A's failures instead of opening its own line")
    }

    /// The fields of the line live in one value, and the switch resets the
    /// value, so a field added later cannot be forgotten in the reset.
    @Test("der Kontowechsel setzt die ganze Geschichte der Leitung zurueck, nicht einzelne Felder", .needsTheSources)
    func theSwitchResetsTheWholeLine() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        let start = try #require(code.range(of: "private func switchIdentity("))
        let end = try #require(code[start.upperBound...].range(of: "private func "))
        let body = code[start.lowerBound..<end.lowerBound]
        #expect(body.contains("lineHistory = LineHistory()"), "the switch leaves the old line's history standing")
        for field in ["openFailures", "lastOpenAttempt", "waitSaidAt", "failedPaths"] {
            // Inside the value the fields are plain `var`; on the carrier
            // they are read through it (`{ get … }`). A `private` declaration
            // without that brace is a stored copy beside the value.
            let stored = code.split(separator: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("private") && trimmed.contains("var \(field)") && !trimmed.contains("{")
            }
            #expect(stored.isEmpty, "\(field) is stored beside the line's history again: \(stored)")
        }
    }

    /// The pending bodies a write loop clears. Only the body that was sent
    /// may go: a later one queued while the write was on its way stays.
    nonisolated static let pendingNames = ["playlistsPending", "choicesPending", "family.pending"]

    /// Clearings of a pending body in `text`: those that ask whether it is
    /// still the sent one, and those that do not.
    nonisolated static func pendingClearings(in text: Substring) -> (guarded: Int, bare: Int) {
        var guarded = 0
        var bare = 0
        for line in text.split(separator: "\n") {
            for name in pendingNames where line.contains("\(name) = nil") {
                if line.contains("if \(name) == body { \(name) = nil }") { guarded += 1 } else { bare += 1 }
            }
        }
        return (guarded, bare)
    }

    /// The rule stands at eight assignments in three write loops; a
    /// ninth without the question, or one that lost it, turns this red.
    @Test("die Schreibschleifen raeumen nur den gesendeten Koerper ab, an jeder Stelle", .needsTheSources)
    func onlyTheSentBodyIsCleared() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        let loops = ["private func sendPlaylists(": 3, "private func sendChoices(": 3, "private func send(_ family:": 2]
        for (head, expected) in loops {
            let start = try #require(code.range(of: head), "\(head) is gone, the witness measures nothing")
            let end = code[start.upperBound...].range(of: "\n    private func ")?.lowerBound ?? code.endIndex
            let found = Self.pendingClearings(in: code[start.lowerBound..<end])
            #expect(found.bare == 0, "\(head) clears a pending body without asking whether it was the sent one")
            #expect(found.guarded == expected, "\(head): \(found.guarded) guarded clearings, the rule counts \(expected)")
        }
        // Calibration: both forms are seen.
        let calibration = Self.pendingClearings(in: "if choicesPending == body { choicesPending = nil }\nchoicesPending = nil")
        #expect(calibration.guarded == 1 && calibration.bare == 1)
    }

    @Test("auf jede Antwort des Dienstes folgt die Frage, ob sie noch dem Konto gilt, auch auf Ansagen der Leitung", .needsTheSources)
    func everyAnswerAsksForItsAccount() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "await transport.").count - 1 == 10, "the fence counts the ten answers of the service")
        #expect(Self.answersWithoutCheck(in: code) == 0, "an answer of the service acts without asking for its account")
        #expect(code.contains("self.stillAsked(generation, \"announcement\""), "an announcement acts without asking for its account")
        #expect(code.contains("self.stillAsked(generation, \"socket close\""), "a close acts without asking for its account")
        // Calibration: an answer without the question, and one with it.
        #expect(Self.answersWithoutCheck(in: "let a = try await transport.fetch(kind: k)\nstands = a") == 1)
        #expect(Self.answersWithoutCheck(in: "let a = try await transport.fetch(kind: k)\nguard stillAsked(g, \"x\", by: c) else { return }") == 0)
    }

    /// Every `await transport.` whose next six lines, up to the next such
    /// call, do not ask `stillAsked(`.
    nonisolated static func answersWithoutCheck(in code: String) -> Int {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let calls = lines.indices.filter { lines[$0].contains("await transport.") }
        return calls.enumerated().filter { index, call in
            let end = min(index + 1 < calls.count ? calls[index + 1] : lines.count, call + 7)
            return !lines[call..<end].contains { $0.contains("stillAsked(") }
        }.count
    }
}
#endif
