// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Sync-Verbindung, die als offen gilt und tot ist: erkannt ohne eigene
/// Uhr, am Wechsel des Netzwegs, am Echo des eigenen Schreibens, an einer
/// Anfrage, die auf der Leitung stirbt; neu geoeffnet mit wachsendem Abstand;
/// was waehrenddessen geschrieben wurde, geht nicht verloren.
@MainActor
struct MaerSyncSilenceTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    typealias FakeAnnouncer = MaerSyncCarrierTests.FakeAnnouncer

    final class FakePath: MaerSyncPathSource {
        var current: MaerSyncPath? = MaerSyncSilenceTests.wifi
        var handlers: [@MainActor (MaerSyncPath) -> Void] = []
        func onChange(_ handler: @escaping @MainActor (MaerSyncPath) -> Void) { handlers.append(handler) }
        func change(to new: MaerSyncPath) {
            current = new
            for handler in handlers { handler(new) }
        }
    }

    static let wifi = MaerSyncPath(satisfied: true, interfaces: ["wifi"])
    static let tunnel = MaerSyncPath(satisfied: true, interfaces: ["wifi", "other"])
    static let cellular = MaerSyncPath(satisfied: true, interfaces: ["cellular"])
    static let none = MaerSyncPath(satisfied: false, interfaces: [])

    final class Clock {
        var now: Double = 1_000_000
    }

    private let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")

    private func rig(announcedKinds: Set<String>? = nil)
        -> (session: MaerSyncSession, transport: FakeTransport, announcer: FakeAnnouncer,
            path: FakePath, clock: Clock, suite: String) {
        let suite = "maer-silence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let path = FakePath()
        let clock = Clock()
        let access = self.access
        let session = MaerSyncSession(transport: transport, announcer: announcer, access: { access },
                                      deviceId: { "dev-a" }, defaults: defaults, path: path,
                                      announcedKinds: announcedKinds, clock: { clock.now })
        return (session, transport, announcer, path, clock, suite)
    }

    /// Waits until the work the session started in its own tasks has done
    /// what the case waits for.
    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    private func claim(_ at: Double) -> PlaybackClaim {
        PlaybackClaim(deviceId: "dev-a", itemId: "rss:a:1", t: at, position: 10, deviceName: "A")
    }

    private func foreignStand(_ transport: FakeTransport) throws {
        transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                               body: try MaerSyncStandsWire.encode(["rss:b:2": [300, 7_000]]))
    }

    @Test("nach einem Wechsel des Netzwegs ist die Verbindung neu und das Verpasste geholt, ohne weiteres Zutun")
    func aChangedPathReopensAndFetches() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        rig.session.start()
        await rig.session.refresh(by: "settle")
        // The start's own round chains in behind; it must be done, or it
        // fetches what the path round is here to fetch.
        await eventually { rig.session.refreshSettled }
        try #require(rig.announcer.isOpen && rig.announcer.opens >= 1, "the socket stood, else the case measures nothing")
        let opensBefore = rig.announcer.opens
        try foreignStand(rig.transport)
        #expect(rig.session.stands["rss:b:2"] == nil, "the silent socket told nothing")

        rig.path.change(to: Self.cellular)
        await eventually { rig.session.stands["rss:b:2"] != nil }
        await eventually { rig.session.refreshSettled }

        #expect(rig.announcer.closes >= 1, "the socket of the old path was dropped")
        #expect(rig.announcer.opens == opensBefore + 1, "and a new one opened")
        #expect(rig.session.stands["rss:b:2"] == [300, 7_000], "what the other device wrote is here")
    }

    @Test("ein stummer Socket beim Spielen wird am ausbleibenden Echo des eigenen Anspruchs erkannt und neu verbunden")
    func aSilentSocketIsFoundByTheMissingEcho() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        try #require(rig.announcer.isOpen)
        try foreignStand(rig.transport)
        let opensBefore = rig.announcer.opens

        // Playing: the own claim goes out; the socket stays silent, its echo
        // never comes.
        rig.session.writeClaim(claim(1), by: "tick")
        await eventually { rig.transport.writes.contains { $0.kind == MaerSyncSession.claimKind } }
        rig.clock.now += 5
        rig.session.writeClaim(claim(2), by: "tick")
        await eventually { rig.transport.writes.filter { $0.kind == MaerSyncSession.claimKind }.count == 2 }
        #expect(rig.announcer.opens == opensBefore, "inside the window nothing is doubted")

        rig.clock.now += 6
        rig.session.writeClaim(claim(3), by: "tick")
        await eventually { rig.session.stands["rss:b:2"] != nil }
        #expect(rig.announcer.opens == opensBefore + 1, "past the window the socket is dropped and opened again")
        #expect(rig.session.stands["rss:b:2"] == [300, 7_000], "and what was missed is fetched")
    }

    @Test("das Echo, das kommt, beweist den Socket; es wird nichts neu verbunden")
    func anArrivingEchoProvesTheSocket() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        let opensBefore = rig.announcer.opens
        rig.session.writeClaim(claim(1), by: "tick")
        await eventually { rig.transport.writes.contains { $0.kind == MaerSyncSession.claimKind } }
        let version = String(rig.transport.documents[FakeTransport.key(MaerSyncSession.claimKind, "dev-a")]?.version ?? 0)
        rig.announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.claimKind, scope: "dev-a", version: version))
        rig.clock.now += 60
        rig.session.writeClaim(claim(2), by: "tick")
        await eventually { rig.transport.writes.filter { $0.kind == MaerSyncSession.claimKind }.count == 2 }
        #expect(rig.announcer.opens == opensBefore, "the echo came, the socket carries")
        #expect(rig.announcer.closes == 0)
    }

    @Test("Eine Runde, die die Steckdose stumm findet, wirft sie ab und holt jedes Dokument genau einmal; keine zweite Runde")
    func aRoundThatFindsTheSocketSilentFetchesOnce() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        try #require(rig.announcer.isOpen, "the socket stood, else the case measures nothing")

        // The own claim goes out, its echo never comes. No write follows
        // after the window, so the first to find the silence is a round.
        rig.session.writeClaim(claim(1), by: "tick")
        await eventually { rig.transport.writes.contains { $0.kind == MaerSyncSession.claimKind } }
        await eventually { rig.session.refreshSettled }
        try foreignStand(rig.transport)
        rig.clock.now += 11
        try #require(rig.announcer.isOpen, "nothing doubted the socket before the round")

        let opensBefore = rig.announcer.opens
        let closesBefore = rig.announcer.closes
        let fetchesBefore = rig.transport.fetches.count
        await rig.session.refresh(by: "occasion")
        await eventually { rig.session.refreshSettled }

        let fetched = Array(rig.transport.fetches.dropFirst(fetchesBefore))
        #expect(rig.announcer.closes == closesBefore + 1, "the silent socket was dropped as stale")
        #expect(rig.announcer.opens == opensBefore + 1, "and the same round opened it again")
        #expect(!fetched.isEmpty, "the round fetched")
        #expect(Set(fetched).count == fetched.count, "a document was fetched twice: \(fetched)")
        #expect(rig.session.peakRounds == 1, "rounds standing at once: \(rig.session.peakRounds)")
        #expect(rig.session.stands["rss:b:2"] == [300, 7_000], "what the other device wrote is here")
    }

    @Test("Eine stale-Antwort vor ihrer Ansage ist kein Befund, wenn die Ansage binnen der Frist kommt")
    func aStaleAnswerBeforeItsAnnouncementIsNoFinding() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        let opensBefore = rig.announcer.opens
        try foreignStand(rig.transport)
        let foreign = String(rig.transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")]?.version ?? 0)
        // The own write meets the foreign version first (stale), the
        // announcement of it comes a second later.
        rig.session.enqueue(upserts: ["rss:a:1": [5, 8_000]], removing: [], by: "tick")
        await eventually { rig.transport.writes.filter { $0.kind == MaerSyncSession.standsKind }.count >= 2 }
        rig.clock.now += 1
        rig.announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.standsKind, scope: "", version: foreign))
        let own = String(rig.transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")]?.version ?? 0)
        rig.announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.standsKind, scope: "", version: own))
        rig.clock.now += 20
        rig.session.enqueue(upserts: ["rss:a:1": [6, 9_000]], removing: [], by: "tick")
        await eventually { rig.transport.writes.filter { $0.kind == MaerSyncSession.standsKind }.count >= 3 }
        #expect(rig.announcer.opens == opensBefore, "no reconnect: the announcement came within the window")
        #expect(rig.announcer.closes == 0)
    }

    @Test("Ein Schreiben ausserhalb der angekuendigten Arten erwartet kein Echo und loest kein stale aus")
    func aKindTheSocketDoesNotAnnounceIsNotAwaited() async throws {
        let rig = rig(announcedKinds: [MaerSyncSession.standsKind])
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        let opensBefore = rig.announcer.opens
        rig.session.writeClaim(claim(1), by: "tick")
        await eventually { rig.transport.writes.contains { $0.kind == MaerSyncSession.claimKind } }
        rig.clock.now += 60
        rig.session.writeClaim(claim(2), by: "tick")
        await eventually { rig.transport.writes.filter { $0.kind == MaerSyncSession.claimKind }.count == 2 }
        #expect(rig.announcer.opens == opensBefore, "the claim is not announced here, so its silence proves nothing")
        #expect(rig.announcer.closes == 0)
    }

    @Test("I5 und I7: eine Anfrage, die auf der Leitung stirbt, wirft den Socket ab; die Warteschlange behaelt und schickt spaeter")
    func aRequestThatDiesOnTheLineDropsTheSocket() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        try #require(rig.announcer.isOpen)
        rig.transport.lineLost = true
        rig.session.enqueue(upserts: ["rss:a:1": [42, 8_000]], removing: [], by: "tick")
        await eventually { !rig.announcer.isOpen }
        #expect(!rig.announcer.isOpen, "the socket on the dead line was dropped")
        #expect(try rig.transport.stands()["rss:a:1"] == nil, "nothing arrived while the line was dead")

        rig.transport.lineLost = false
        rig.clock.now += 1
        rig.session.writeClaim(claim(1), by: "tick")
        await eventually { (try? rig.transport.stands()["rss:a:1"]) != nil }
        #expect(try rig.transport.stands()["rss:a:1"] == [42, 8_000], "I7: the queue kept the stand and sent it once the line carried")
        #expect(rig.announcer.isOpen, "the next occasion opened the socket again")
    }

    @Test("in einem Netz, das nichts durchlaesst, oeffnet eine Minute Anlaesse im Sekundentakt hoechstens sechsmal; danach genau ein Nachholen")
    func aDyingNetworkIsNotRushed() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        try #require(rig.announcer.isOpen)
        let opensBefore = rig.announcer.opens
        rig.announcer.failOpens = true
        rig.announcer.drop()
        for second in 1...60 {
            rig.clock.now += 1
            rig.session.writeClaim(claim(Double(second)), by: "tick")
            await eventually { rig.session.refreshSettled }
        }
        let attempts = rig.announcer.opens - opensBefore
        #expect(attempts >= 1 && attempts <= 6, "opens in a minute of dying network: \(attempts)")

        // The network carries again, and something was written meanwhile.
        rig.announcer.failOpens = false
        try foreignStand(rig.transport)
        let fetchesBefore = rig.transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.standsKind, "") }.count
        rig.clock.now += 200
        rig.session.writeClaim(claim(100), by: "tick")
        await eventually { rig.session.stands["rss:b:2"] != nil }
        await eventually { rig.session.refreshSettled }
        let fetched = rig.transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.standsKind, "") }.count - fetchesBefore
        #expect(rig.announcer.isOpen)
        #expect(fetched == 1, "what was missed is fetched exactly once: \(fetched)")
    }

    /// Ein flatternder Netzweg (Tunnel, VPN, Funkzellengrenze) darf die
    /// Wartezeit nach gescheiterten Oeffnungen nicht aushebeln. Ein Wechsel hebt die
    /// Wartezeit nur auf einem tragenden Weg auf, auf dem noch keine
    /// Oeffnung scheiterte; ein Wechsel ohne Netz startet keine Runde;
    /// Anlaesse waehrend einer Runde ergeben hoechstens eine wartende.
    @Test("Ein flatternder Netzweg haelt die Wartezeit, fasst Runden zusammen und holt nach der Rueckkehr genau einmal nach")
    func aFlappingPathIsNotRushed() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        rig.session.start()
        await rig.session.refresh(by: "settle")
        await eventually { rig.session.refreshSettled }
        try #require(rig.announcer.isOpen)
        rig.announcer.failOpens = true
        rig.transport.offline = true

        // Ein Stoss: zwanzig Wechsel ohne Pause. Hoechstens eine laufende und
        // eine wartende Runde.
        let swings = [Self.tunnel, Self.none, Self.wifi, Self.none]
        for i in 0..<20 { rig.path.change(to: swings[i % 4]) }
        await eventually { rig.session.refreshSettled }
        #expect(rig.session.peakRounds <= 2, "rounds standing at once: \(rig.session.peakRounds)")

        // Ein Flattern ueber zehn Sekunden. Nach der Regel hoechstens vier
        // Oeffnungen: je eine auf den zwei neuen Wegen, dann 2 s und 4 s
        // Abstand; ohne die Bedingung waere es jeder tragende Wechsel.
        rig.clock.now += 200
        let opensBefore = rig.announcer.opens
        var requestsOnNone = 0
        for i in 0..<20 {
            rig.clock.now += 0.5
            let before = rig.transport.requests
            rig.path.change(to: swings[(i + 2) % 4])
            await eventually { rig.session.refreshSettled }
            if swings[(i + 2) % 4] == Self.none { requestsOnNone += rig.transport.requests - before }
        }
        let opens = rig.announcer.opens - opensBefore
        #expect(opens >= 1 && opens <= 4, "opens while the path flapped: \(opens)")
        #expect(requestsOnNone == 0, "a change without network asks nothing")

        // Das Netz traegt wieder, ein anderes Geraet hat geschrieben.
        rig.announcer.failOpens = false
        rig.transport.offline = false
        try foreignStand(rig.transport)
        let fetchesBefore = rig.transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.standsKind, "") }.count
        rig.path.change(to: Self.cellular)
        await eventually { rig.session.stands["rss:b:2"] != nil }
        await eventually { rig.session.refreshSettled }
        let fetched = rig.transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.standsKind, "") }.count - fetchesBefore
        #expect(rig.announcer.isOpen)
        #expect(fetched == 1, "after the last change exactly one fetch: \(fetched)")
    }

    @Test("I3 und I4: kein Zeitgeber in der Sitzung, und jedes Ende nennt seinen Anlass", .needsTheSources)
    func noClockAndEveryEndNamesItsCause() throws {
        let session = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        for clock in ["Timer", "Task.sleep", "asyncAfter", "DispatchQueue"] {
            #expect(!session.contains(clock), "the session keeps no clock: \(clock)")
        }
        #expect(session.contains("MAERSYNC socket dropped cause="))
        let socket = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"), encoding: .utf8))
        #expect(socket.contains("cause=\\(MaerSyncLiveness.Cause.closed.rawValue"))
    }

    @Test("in Ruhe fragt die Sitzung nichts, auch nicht nach langer Zeit")
    func restAsksNothing() async throws {
        let rig = rig()
        defer { UserDefaults().removePersistentDomain(forName: rig.suite) }
        await rig.session.refresh(by: "start")
        let requests = rig.transport.requests
        rig.clock.now += 3_600
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.transport.requests == requests, "no request without an occasion")
    }

    @Test("Die Regeln: Fenster, Wartezeit, und welche Fehler die Leitung meinen")
    func theRules() {
        let awaited = [MaerSyncLiveness.Awaited(kind: "claim", scope: "a", version: "3", since: 100)]
        #expect(!MaerSyncLiveness.isSilent(awaited, now: 109))
        #expect(MaerSyncLiveness.isSilent(awaited, now: 110))
        #expect(!MaerSyncLiveness.isSilent([], now: 1_000))
        #expect(MaerSyncLiveness.awaits(kind: "claim", version: "4", announcedKinds: ["claim"], alreadyAnnounced: "3"))
        #expect(!MaerSyncLiveness.awaits(kind: "claim", version: "4", announcedKinds: ["claim"], alreadyAnnounced: "4"),
                "an echo that came before the answer is not waited for")
        #expect(!MaerSyncLiveness.awaits(kind: "stats", version: "4", announcedKinds: ["claim"], alreadyAnnounced: nil))
        #expect((1...7).map { MaerSyncReopen.wait(afterFailures: $0) } == [2, 4, 8, 16, 32, 64, 120])
        #expect(MaerSyncReopen.wait(afterFailures: 0) == 0)
        #expect(MaerSyncReopen.mayOpen(failures: 3, lastAttempt: 100, now: 108))
        #expect(!MaerSyncReopen.mayOpen(failures: 3, lastAttempt: 100, now: 107))
        #expect(MaerSyncLiveness.isLineLoss(URLError(.timedOut)))
        #expect(MaerSyncLiveness.isLineLoss(URLError(.networkConnectionLost)))
        #expect(!MaerSyncLiveness.isLineLoss(URLError(.badServerResponse)))
        #expect(!MaerSyncLiveness.isLineLoss(MaerSyncFailure.status(503)), "a service that answers is not a dead line")
        // The path lifts the wait only where it carries and nothing failed yet.
        #expect(MaerSyncReopen.pathLiftsTheWait(Self.tunnel, failedOn: [Self.wifi]))
        #expect(!MaerSyncReopen.pathLiftsTheWait(Self.wifi, failedOn: [Self.wifi, Self.tunnel]))
        #expect(!MaerSyncReopen.pathLiftsTheWait(Self.none, failedOn: []))
    }

    final class AccessBox {
        var access: MaerSyncAccess?
    }

    /// Sign in, sign out, sign in again in one run: `start()` runs once per
    /// process, so the second sign-in must fetch and open on its own, with
    /// no foreground, tick or path change in between.
    @Test("an, ab, an im selben Lauf: die zweite Anmeldung holt sofort und oeffnet den Socket")
    func aSecondSignInFetchesRightAway() async throws {
        let suite = "maer-silence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let path = FakePath()
        let clock = Clock()
        let box = AccessBox()
        box.access = access
        let session = MaerSyncSession(transport: transport, announcer: announcer, access: { box.access },
                                      deviceId: { "dev-a" }, defaults: defaults, path: path,
                                      announcedKinds: nil, clock: { clock.now })
        session.start()
        await eventually { session.refreshSettled && announcer.isOpen }
        try #require(announcer.isOpen, "the first sign-in stood, else the case measures nothing")

        box.access = nil
        session.reloadAccess()
        #expect(!announcer.isOpen, "the sign-out closed the socket")
        try foreignStand(transport)
        let opensBefore = announcer.opens

        box.access = access
        session.reloadAccess()
        await eventually { session.stands["rss:b:2"] != nil }
        await eventually { session.refreshSettled }
        #expect(session.stands["rss:b:2"] == [300, 7_000], "what the other device wrote is here, no further occasion")
        #expect(announcer.isOpen && announcer.opens == opensBefore + 1, "and the socket is open again")
    }
}
#endif
