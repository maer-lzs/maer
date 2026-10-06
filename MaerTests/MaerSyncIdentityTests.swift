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
}
#endif
