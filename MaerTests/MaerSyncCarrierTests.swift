// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Mär sync service as carrier, over a fake transport that keeps the
/// service's gates: a write names the version it read or is stale, an
/// empty state never replaces a full one, a pot that shrank below half is
/// refused unless declared. The stands go out as one document and come
/// back merged when the version moved under them; the claim goes to its
/// own scope and never anywhere else; an announcement fetches and wakes;
/// a refused token stops everything until the next sign-in.
@MainActor
struct MaerSyncCarrierTests {
    @MainActor
    final class FakeTransport: MaerSyncTransport {
        struct Stored {
            var body: Data
            var format: Int
            var version: Int
        }

        struct Write {
            var kind: String
            var scope: String
            var ifMatch: String?
            var declared: Bool
            var bytes: Int
        }

        var documents: [String: Stored] = [:]
        var writes: [Write] = []
        var fetches: [String] = []
        var listings = 0
        var refuseNextWrite: String?
        /// The next write is refused as stale while the stored version stays
        /// put. That is the case a device meets when another path already
        /// took the document it is about to be told about: the re-read after
        /// the refusal then reports nothing new.
        var staleNextWrite = false
        /// Every write is refused with this sentence while it is set.
        var refuseEveryWrite: String?
        var unauthorized = false
        var offline = false
        /// The line died under the request: the platform's own error, not a
        /// service answer.
        var lineLost = false
        /// The platform refuses the plain http address before a byte
        /// leaves: App Transport Security's URLError, not a status.
        var platformRefuses = false
        var refuseToken = false
        /// The proxy answers 403: the service stands, but not from here.
        var blockToken = false
        var tokenRequests = 0
        var lastTokenDevice = ""
        /// A fetch of this kind reads its answer, then lets `then` run
        /// before it hands the answer back: the account changes while an
        /// answer is on its way.
        var answerHeld: (kind: String, then: () async -> Void)?
        /// Runs once inside the next write, before it answers: a newer body
        /// is queued while the one on its way is still out.
        var duringWrite: (() -> Void)?

        nonisolated static func key(_ kind: String, _ scope: String) -> String { "\(kind)|\(scope)" }

        func fetch(kind: String, scope: String, access: MaerSyncAccess) async throws -> MaerSyncDocument? {
            try gate()
            fetches.append(Self.key(kind, scope))
            let answer = documents[Self.key(kind, scope)]
                .map { MaerSyncDocument(body: $0.body, format: $0.format, etag: String($0.version)) }
            if let held = answerHeld, held.kind == kind {
                answerHeld = nil
                await held.then()
            }
            return answer
        }

        func write(kind: String, scope: String, body: Data, format: Int, ifMatch: String?,
                   declaredShrink: Bool, access: MaerSyncAccess) async throws -> MaerSyncWriteOutcome {
            try gate()
            writes.append(Write(kind: kind, scope: scope, ifMatch: ifMatch, declared: declaredShrink, bytes: body.count))
            if let during = duringWrite {
                duringWrite = nil
                during()
            }
            if let reason = refuseNextWrite {
                refuseNextWrite = nil
                return .refused(reason: reason)
            }
            if let reason = refuseEveryWrite { return .refused(reason: reason) }
            if staleNextWrite {
                staleNextWrite = false
                return .stale(current: documents[Self.key(kind, scope)].map { String($0.version) })
            }
            let held = documents[Self.key(kind, scope)]
            if let held {
                guard let ifMatch, ifMatch == String(held.version) else { return .stale(current: String(held.version)) }
            } else if ifMatch != nil {
                return .stale(current: nil)
            }
            // The service's gates, as far as a witness needs them.
            if let held, !declaredShrink {
                if body.isEmpty, !held.body.isEmpty { return .refused(reason: "an empty state never replaces a full one") }
                if Double(body.count) < Double(held.body.count) * 0.5 { return .refused(reason: "shrank below the floor") }
            }
            let version = (held?.version ?? 0) + 1
            documents[Self.key(kind, scope)] = Stored(body: body, format: format, version: version)
            return .written(etag: String(version))
        }

        func list(kind: String, access: MaerSyncAccess) async throws -> [MaerSyncListed] {
            try gate()
            listings += 1
            return documents
                .filter { $0.key.hasPrefix(kind + "|") }
                .map { MaerSyncListed(scope: String($0.key.dropFirst(kind.count + 1)),
                                      etag: String($0.value.version), format: $0.value.format) }
                .sorted { $0.scope < $1.scope }
        }

        func token(owner: String, proof: String, device: String, at baseURL: URL) async throws -> String {
            try gate()
            tokenRequests += 1
            lastTokenDevice = device
            lastProof = proof
            if refuseToken { throw MaerSyncFailure.unauthorized }
            if blockToken { throw MaerSyncFailure.status(403) }
            if let wait = tooManyAttempts { throw MaerSyncFailure.tooManyAttempts(retryAfter: wait) }
            return "a-token"
        }

        /// What `/v1/salt` answers. 16 bytes and the contract's rounds, so
        /// the sign-in derives for real; `saltForm` drives the move case.
        var saltForm = MaerSyncSalt.Form.proof
        var saltRounds = 600_000
        var saltRequests = 0
        var lastProof: String?
        var tooManyAttempts: Int??
        func salt(owner: String, at baseURL: URL) async throws -> MaerSyncSalt {
            try gate()
            saltRequests += 1
            return MaerSyncSalt(salt: Data(repeating: 1, count: 16), rounds: saltRounds, form: saltForm)
        }

        var passwordChanges: [(current: MaerSyncCurrent, new: MaerSyncNewPassword)] = []
        func changePassword(owner: String, device: String, current: MaerSyncCurrent,
                            new: MaerSyncNewPassword, at baseURL: URL) async throws -> String {
            try gate()
            passwordChanges.append((current, new))
            return "a-token"
        }

        /// The status the health route answers with. `healthStatus` lets a
        /// case drive a refusal that is not a throw, which is exactly the
        /// shape a proxy gives from outside its network.
        var healthStatus: Int? = 200
        func health(at baseURL: URL) async throws -> Int? {
            try gate()
            return healthStatus
        }

        /// What the key path answers: the BYTES, and beside them the label
        /// the service would print. The two are separate on purpose, so a
        /// witness can move one without the other: the sign-in must hang on
        /// the bytes, and a label that stays while the bytes move is the
        /// case a man in the middle would produce. `keyPathAbsent` makes the
        /// path answer as an older service does, `keyNotMade` as a service
        /// whose operator has not made one.
        var serviceKeyBytes = Data(repeating: 7, count: 32)
        var serviceLabel = "9ER6-Z3JE-79VH-BMG1-TNSX-1AJ2"
        var keyPathAbsent = false
        var keyNotMade = false
        var keyRequests = 0
        /// The fingerprint a correct door would compute for the bytes.
        var serviceFingerprint: String { ServiceKeyFingerprint.written(for: serviceKeyBytes)! }
        /// The contract version the key path names; nil as if unsent.
        var serviceContract: Int? = 6
        func serviceKey(at baseURL: URL) async throws -> MaerSyncServiceKey {
            try gate()
            keyRequests += 1
            if keyNotMade { throw MaerSyncFailure.serviceHasNoKey }
            if keyPathAbsent { throw MaerSyncFailure.serviceIsOlder }
            return MaerSyncServiceKey(key: serviceKeyBytes, fingerprint: serviceLabel, contract: serviceContract)
        }

        /// The service offers a different key than the one held: every way
        /// that goes through the tunnel meets this before anything is sent.
        var keyChanged: (held: String, offered: String)?
        /// The token was withdrawn by a password change on another device.
        var passwordWithdrawn = false
        /// The service is older than the app: every request is
        /// answered the way `MaerSyncAnswer` reads a 404 key or a 426.
        var serviceOlder = false
        /// Every request that reached the service, of any way.
        var requests = 0

        private func gate() throws {
            requests += 1
            if serviceOlder { throw MaerSyncFailure.serviceIsOlder }
            if unauthorized { throw MaerSyncFailure.unauthorized }
            if passwordWithdrawn { throw MaerSyncFailure.passwordChanged }
            if let keyChanged { throw MaerSyncFailure.serviceKeyChanged(held: keyChanged.held, offered: keyChanged.offered) }
            if offline { throw MaerSyncFailure.status(503) }
            if lineLost { throw URLError(.networkConnectionLost) }
            if platformRefuses { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        }

        /// Another device wrote; the version moves.
        @discardableResult
        func foreignWrite(kind: String, scope: String, body: Data, format: Int = 1) -> String {
            let version = (documents[Self.key(kind, scope)]?.version ?? 0) + 1
            documents[Self.key(kind, scope)] = Stored(body: body, format: format, version: version)
            return String(version)
        }

        func stands() throws -> [String: [Double]] {
            guard let held = documents[Self.key(MaerSyncSession.standsKind, "")] else { return [:] }
            return try MaerSyncStandsWire.decode(held.body)
        }
    }

    @MainActor
    final class FakeAnnouncer: MaerSyncAnnouncer {
        var isOpen = false
        var opens = 0
        var closes = 0
        var onAnnouncement: (@MainActor (MaerSyncAnnouncement) -> Void)?
        var onClose: (@MainActor (Bool) -> Void)?
        /// Every open fails at once (the line never stands), as on a network
        /// that lets nothing through.
        var failOpens = false

        func open(access: MaerSyncAccess,
                  onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
                  onClose: @escaping @MainActor (Bool) -> Void) {
            opens += 1
            self.onAnnouncement = onAnnouncement
            self.onClose = onClose
            if failOpens {
                isOpen = false
                onClose(false)
                return
            }
            isOpen = true
        }

        func close() {
            if isOpen { closes += 1 }
            isOpen = false
        }

        func announce(_ announcement: MaerSyncAnnouncement) { onAnnouncement?(announcement) }

        /// The socket died under the session after it stood.
        func drop() {
            isOpen = false
            onClose?(true)
        }
    }

    private let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")

    private func suite() -> (UserDefaults, String) {
        let name = "maer-sync-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func session(_ transport: FakeTransport, _ announcer: FakeAnnouncer, defaults: UserDefaults,
                         access: MaerSyncAccess? = nil, deviceId: String = "dev-a") -> MaerSyncSession {
        let access = access ?? self.access
        return MaerSyncSession(transport: transport, announcer: announcer, access: { access },
                               deviceId: { deviceId }, defaults: defaults)
    }

    // MARK: - The stands

    @Test("der erste Schrieb legt den Topf an, der zweite nennt die Fassung des ersten")
    func firstWriteLaysDownThePot() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let carrier = MaerSyncStandCarrier(session: session(transport, FakeAnnouncer(), defaults: defaults))
        #expect(carrier.name == "maer-sync")
        #expect(!carrier.hasRoomLimit, "the service has no ceiling")
        #expect(carrier.historyService == .maerSync)

        carrier.write(upserts: ["rss:a:1": [100, 1_000, 3_600], "rss:b:2": [0, 900]], removing: [], by: "witness")
        #expect(carrier.stands()["rss:a:1"] == [100, 1_000, 3_600], "the mirror answers at once")
        await carrier.refresh(by: "witness")
        #expect(try transport.stands()["rss:a:1"] == [100, 1_000, 3_600])
        #expect(transport.writes.first?.ifMatch == nil, "a first write names no version")
        #expect(transport.writes.first?.declared == false)

        carrier.write(upserts: ["rss:c:3": [5, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(transport.writes.last?.ifMatch == "1", "the second write names the version the first got")
        #expect(try transport.stands().keys.sorted() == ["rss:a:1", "rss:b:2", "rss:c:3"])
        #expect(transport.writes.allSatisfy { !$0.declared }, "the stands never declare a shrink")
    }

    @Test("eine Fassung, die sich unter dem Schrieb bewegt hat, wird geholt und zusammengefuehrt, nicht ueberschrieben")
    func aMovedVersionIsMergedNotOverwritten() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let carrier = MaerSyncStandCarrier(session: session(transport, announcer, defaults: defaults))
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")

        // The other device moved on: a newer stand for a, and a stand for b
        // this device has never seen. The version is now 2.
        transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                               body: try MaerSyncStandsWire.encode(["rss:a:1": [200, 5_000], "rss:b:2": [30, 4_000]]))
        var woken = 0
        carrier.start { woken += 1 }
        // This device writes an OLDER a and a new c, naming version 1.
        carrier.write(upserts: ["rss:a:1": [150, 3_000], "rss:c:3": [7, 6_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")

        let served = try transport.stands()
        #expect(served["rss:a:1"] == [200, 5_000], "the newer moment wins, and it was the other device's")
        #expect(served["rss:b:2"] == [30, 4_000], "what the other device wrote survives the write")
        #expect(served["rss:c:3"] == [7, 6_000], "and what this device wrote lands")
        #expect(carrier.stands()["rss:a:1"] == [200, 5_000], "the mirror carries the merged pot")
        #expect(woken == 1, "the foreign stands woke the runner once")
        #expect(transport.writes.filter { $0.kind == MaerSyncSession.standsKind }.map(\.ifMatch) == [nil, "1", "2"],
                "one stale write, then the repeat names the version that was fetched")
    }

    @Test("eine Abweisung haelt die Warteschlange, erklaert nichts und ueberlebt den Neustart")
    func aRefusalKeepsTheQueueAndDeclaresNothing() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        var carrier = MaerSyncStandCarrier(session: session(transport, FakeAnnouncer(), defaults: defaults))
        transport.refuseEveryWrite = "shrank below the floor"
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        await carrier.refresh(by: "tick")
        #expect(try transport.stands().isEmpty, "nothing landed")
        #expect(transport.writes.count >= 2, "every occasion tried again: \(transport.writes.count)")
        #expect(transport.writes.allSatisfy { !$0.declared }, "a refusal is never answered with a declaration")

        // A new session over the same defaults: the queue is still there
        // and goes out on the next occasion, once the service takes it.
        transport.refuseEveryWrite = nil
        carrier = MaerSyncStandCarrier(session: session(transport, FakeAnnouncer(), defaults: defaults))
        #expect(carrier.stands()["rss:a:1"] == [100, 1_000], "the mirror survives the restart")
        await carrier.refresh(by: "witness")
        #expect(try transport.stands()["rss:a:1"] == [100, 1_000])
    }

    @Test("eine Meldung mit fremder Fassung holt den Topf und weckt den Laeufer; die eigene Fassung ist bekannt")
    func anAnnouncementFetchesAndWakes() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let carrier = MaerSyncStandCarrier(session: session(transport, announcer, defaults: defaults))
        var woken = 0
        carrier.start { woken += 1 }
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        // The start's own round is chained behind the first; a second
        // round drains it, so the counts below are the announcement's.
        await carrier.refresh(by: "drain")
        #expect(announcer.opens == 1, "the round opened the socket")
        let fetchesBefore = transport.fetches.count

        // The own write comes back as an announcement at the version this
        // device just stored: known, nothing to fetch. Every round fetches
        // the stands pot, the playlists document AND the choices document
        // once on its own, so a settle round adds exactly three.
        announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.standsKind, scope: "", version: "1"))
        await carrier.refresh(by: "settle")
        #expect(transport.fetches.count == fetchesBefore + 3, "the settle round fetched stands, playlists and choices, the announcement nothing")
        #expect(woken == 0)

        // Another device wrote version 2.
        let version = transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "",
                                             body: try MaerSyncStandsWire.encode(["rss:a:1": [100, 1_000], "rss:z:9": [1, 9_000]]))
        announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.standsKind, scope: "", version: version))
        await carrier.refresh(by: "settle")
        #expect(carrier.stands()["rss:z:9"] == [1, 9_000])
        #expect(woken == 1, "the foreign write woke the runner once")
    }

    @Test("ein gestorbener Socket wird beim naechsten Anlass wieder geoeffnet, nie von selbst")
    func theSocketReopensOnTheNextOccasion() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let announcer = FakeAnnouncer()
        let carrier = MaerSyncStandCarrier(session: session(FakeTransport(), announcer, defaults: defaults))
        await carrier.refresh(by: "witness")
        #expect(announcer.opens == 1)
        announcer.drop()
        #expect(announcer.opens == 1, "nothing reconnects on its own")
        await carrier.refresh(by: "tick")
        #expect(announcer.opens == 2, "the next occasion opened it again")
        await carrier.refresh(by: "tick")
        #expect(announcer.opens == 2, "an open socket is left alone")
    }

    @Test("ein abgewiesenes Zeichen haelt jede Runde an, bis die Anmeldung es aufhebt")
    func unauthorizedStopsUntilSignIn() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let session = session(transport, announcer, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.unauthorized = true
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.unauthorized)
        #expect(carrier.name == "maer-sync signed out")
        #expect(!announcer.isOpen, "the socket closed with the sign-out")
        let calls = transport.writes.count + transport.fetches.count + transport.listings
        await carrier.refresh(by: "tick")
        #expect(transport.writes.count + transport.fetches.count + transport.listings == calls,
                "no round runs against a refused token")

        transport.unauthorized = false
        session.reloadAccess()
        await carrier.refresh(by: "sign-in")
        #expect(!session.unauthorized)
        #expect(transport.writes.count > calls, "the queue went out after the sign-in")
    }

    @Test("ein durch einen Passwortwechsel zurueckgezogenes Zeichen haelt jede Runde an wie ein abgewiesenes")
    func aWithdrawnTokenStopsLikeARefusedOne() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let session = session(transport, announcer, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.passwordWithdrawn = true
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.unauthorized, "the rounds stop")
        #expect(!announcer.isOpen, "the socket closed")
        let calls = transport.writes.count + transport.fetches.count + transport.listings
        await carrier.refresh(by: "tick")
        #expect(transport.writes.count + transport.fetches.count + transport.listings == calls,
                "no round runs against a withdrawn token")
        #expect(session.passwordWithdrawn, "and the session knows why, for the page's sentence")

        // A new sign-in forgets the reason; a plain refusal carries none.
        transport.passwordWithdrawn = false
        session.reloadAccess()
        #expect(!session.passwordWithdrawn && !session.unauthorized)
        transport.unauthorized = true
        await carrier.refresh(by: "witness")
        #expect(session.unauthorized && !session.passwordWithdrawn, "a refused token is not a withdrawn one")
    }

    @Test("ein anderer Schluessel des Dienstes haelt jede Runde an, bis jemand ihn angenommen hat")
    func aChangedServiceKeyStopsUntilSomebodyLooks() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let session = session(transport, announcer, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.keyChanged = (held: "AAAA-BBBB", offered: "CCCC-DDDD")
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.keyChange == MaerSyncKeyChange(held: "AAAA-BBBB", offered: "CCCC-DDDD"), "the event is kept for the page")
        #expect(!session.unauthorized, "a changed key is not a refused token")
        #expect(!announcer.isOpen, "the socket closed with it")
        let calls = transport.writes.count + transport.fetches.count + transport.listings
        await carrier.refresh(by: "tick")
        #expect(transport.writes.count + transport.fetches.count + transport.listings == calls,
                "no round runs against a key nobody has looked at")

        // The person accepted on the page: the pin is held there, and the
        // session is told to read its access again, which clears the event.
        transport.keyChanged = nil
        session.reloadAccess()
        #expect(session.keyChange == nil)
        await carrier.refresh(by: "accepted")
        #expect(transport.writes.count > calls, "the queue went out after the acceptance")
    }

    /// Diese Zusage hat sich am 15.09. geaendert, und zwar am Geraet:
    /// „der naechste Schrieb ueberschreibt ihn nicht" war als Vorsicht
    /// gemeint und war eine Aussperrung. Am Dienst lag ein abgeschnittenes
    /// Dokument, das Geraet behielt seine alte Fassung, jeder Schrieb kam als
    /// 412 zurueck, und stundenlang wurde kein Hoerstand gespeichert. Der
    /// SPIEGEL bleibt weiter (unlesbar ist nicht leer), die FASSUNG wird
    /// genommen, damit der naechste Schrieb landen kann.
    @Test("ein unlesbarer Topf laesst den Spiegel stehen, sperrt das Geraet aber nicht aus")
    func anUnreadablePotLeavesTheMirror() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let carrier = MaerSyncStandCarrier(session: session(transport, FakeAnnouncer(), defaults: defaults))
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        transport.foreignWrite(kind: MaerSyncSession.standsKind, scope: "", body: Data("not a pot".utf8))
        await carrier.refresh(by: "witness")
        #expect(carrier.stands()["rss:a:1"] == [100, 1_000], "the mirror stays")
        carrier.write(upserts: ["rss:b:2": [5, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        let held = try #require(transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")])
        #expect(held.body != Data("not a pot".utf8),
                "der Schrieb ist nie gelandet: das Geraet steht in der Sackgasse")
        let pot = try MaerSyncStandsWire.decode(held.body)
        #expect(pot["rss:b:2"] == [5, 2_000], "der neue Hoerstand fehlt am Dienst")
        #expect(pot["rss:a:1"] == [100, 1_000], "der Spiegel wurde weggeworfen statt behalten")
    }

    // MARK: - The claim

    @Test("der eigene Anspruch geht in den eigenen Scope, erklaert den Schrumpf und sonst nirgendwohin")
    func theOwnClaimGoesToItsOwnScope() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncClaimCarrier(session: session)
        let claim = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: 1_000, position: 12, duration: 300,
                                  title: "A long title that a release will not carry", playAt: 1_000, deviceName: "iPhone")
        carrier.write(claim)
        await session.refresh(by: "witness")
        let writes = transport.writes.filter { $0.kind == MaerSyncSession.claimKind }
        #expect(writes.map(\.scope) == ["dev-a"])
        #expect(writes.first?.declared == true, "a claim is a signal, not a state")
        let stored = try #require(transport.documents[FakeTransport.key(MaerSyncSession.claimKind, "dev-a")])
        #expect(MaerSyncClaimWire.decode(stored.body) == claim)

        // The release is smaller and still lands, named against the version.
        carrier.write(PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: 2_000, released: true, position: 20))
        await session.refresh(by: "witness")
        #expect(transport.writes.last?.ifMatch == "1")
        #expect(MaerSyncClaimWire.decode(transport.documents[FakeTransport.key(MaerSyncSession.claimKind, "dev-a")]!.body)?.released == true)
    }

    @Test("ein aelterer Dienst haelt die Laeufe an, statt bei jeder Gelegenheit neu zu fragen; eine neue Anmeldung fragt wieder")
    func anOlderServiceStopsTheRounds() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.serviceOlder = true
        let announcer = FakeAnnouncer()
        let session = session(transport, announcer, defaults: defaults)
        await session.refresh(by: "scene active")
        #expect(session.serviceOlder && session.halted, "the first answer stops the rounds")
        let asked = transport.requests
        #expect(asked > 0)
        // Every occasion asked again and met the same 426.
        await session.refresh(by: "start")
        await session.refresh(by: "housekeeping")
        #expect(transport.requests == asked, "no occasion asks again")
        #expect(announcer.isOpen == false, "the socket stays shut")
        // A new sign-in (or start) asks once more.
        transport.serviceOlder = false
        session.reloadAccess()
        #expect(!session.serviceOlder)
        await session.refresh(by: "sign-in")
        #expect(transport.requests > asked)
    }

    @Test("fremde Ansprueche kommen ueber die Liste, nur bei unbekannter Fassung geholt; ein verschwundener Scope geht")
    func foreignClaimsComeThroughTheListing() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncClaimCarrier(session: session)
        var woken = 0
        carrier.start { woken += 1 }
        let foreign = PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep", t: 5_000, playAt: 5_000)
        transport.foreignWrite(kind: MaerSyncSession.claimKind, scope: "dev-b", body: try MaerSyncClaimWire.encode(foreign))
        await session.refresh(by: "witness")
        #expect(carrier.claims() == [foreign])
        #expect(woken == 1)
        let fetches = transport.fetches.filter { $0.hasPrefix(MaerSyncSession.claimKind) }.count

        await session.refresh(by: "tick")
        #expect(transport.fetches.filter { $0.hasPrefix(MaerSyncSession.claimKind) }.count == fetches,
                "a version already seen is not fetched again")
        #expect(woken == 1)

        transport.documents[FakeTransport.key(MaerSyncSession.claimKind, "dev-b")] = nil
        await session.refresh(by: "tick")
        #expect(carrier.claims().isEmpty, "a scope no longer listed is gone")
        #expect(woken == 2)
    }

    @Test("eine Meldung fuer den Scope eines anderen Geraets holt ihn; die eigene wird uebergangen")
    func aClaimAnnouncementFetchesTheOneScope() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let announcer = FakeAnnouncer()
        let session = session(transport, announcer, defaults: defaults)
        let carrier = MaerSyncClaimCarrier(session: session)
        var woken = 0
        carrier.start { woken += 1 }
        await session.refresh(by: "witness")
        let foreign = PlaybackClaim(deviceId: "dev-b", itemId: "rss:f:ep", t: 5_000, playAt: 5_000)
        let version = transport.foreignWrite(kind: MaerSyncSession.claimKind, scope: "dev-b",
                                             body: try MaerSyncClaimWire.encode(foreign))
        announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.claimKind, scope: "dev-b", version: version))
        // The announcement's fetch runs in its own task; a settle round
        // waits behind it and lists once more.
        await session.refresh(by: "settle")
        #expect(carrier.claims() == [foreign])
        #expect(woken >= 1)
        let fetches = transport.fetches.count
        announcer.announce(MaerSyncAnnouncement(kind: MaerSyncSession.claimKind, scope: "dev-a", version: "9"))
        await session.refresh(by: "settle")
        #expect(transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.claimKind, "dev-a") }.isEmpty,
                "the own scope is never fetched, whatever is announced for it")
        #expect(transport.fetches.count >= fetches)
    }

    @Test("eine Waise wird nur hier vergessen, nie auf dem Dienst; der Dienst hat keinen Deckel")
    func removeIsLocalOnly() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncClaimCarrier(session: session)
        let orphan = PlaybackClaim(deviceId: "dev-old", itemId: "rss:f:ep", t: 1)
        transport.foreignWrite(kind: MaerSyncSession.claimKind, scope: "dev-old", body: try MaerSyncClaimWire.encode(orphan))
        await session.refresh(by: "witness")
        #expect(carrier.claims() == [orphan])
        let writes = transport.writes.count
        let orphanKey = FakeTransport.key(MaerSyncSession.claimKind, "dev-old")
        let orphanFetches = transport.fetches.filter { $0 == orphanKey }.count
        carrier.remove(deviceId: "dev-old")
        #expect(carrier.claims().isEmpty)
        #expect(transport.writes.count == writes, "nothing was written for the removal")
        #expect(transport.documents[orphanKey] != nil, "the service keeps it")
        await session.refresh(by: "tick")
        #expect(transport.fetches.filter { $0 == orphanKey }.count == orphanFetches,
                "the version stays known, so the orphan is not fetched again")
        #expect(carrier.claims().isEmpty)
    }

    // MARK: - The wire and the addresses

    @Test("der Anspruch reist als seine Plist-Form: jedes Feld kommt zurueck")
    func theClaimWireRoundTrips() throws {
        let full = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: 1_000, released: true, position: 12.5,
                                 duration: 300, title: "Title", playAt: 900, deviceName: "iPad")
        #expect(MaerSyncClaimWire.decode(try MaerSyncClaimWire.encode(full)) == full)
        let bare = PlaybackClaim(deviceId: "dev-a", itemId: "rss:f:ep", t: 1_000)
        #expect(MaerSyncClaimWire.decode(try MaerSyncClaimWire.encode(bare)) == bare)
        #expect(MaerSyncClaimWire.decode(Data("nonsense".utf8)) == nil)
    }

    @Test("der Topf reist als JSON mit sortierten Schluesseln; halbe Eintraege fallen, Unlesbares wirft")
    func theStandsWireIsStableAndStrict() throws {
        let pot: [String: [Double]] = ["b": [1, 2], "a": [3, 4, 5, 6]]
        let bytes = try MaerSyncStandsWire.encode(pot)
        #expect(try MaerSyncStandsWire.encode(pot) == bytes, "the same pot gives the same bytes")
        #expect(String(decoding: bytes, as: UTF8.self).hasPrefix("{\"a\""), "keys are sorted")
        #expect(try MaerSyncStandsWire.decode(bytes) == pot)
        #expect(try MaerSyncStandsWire.decode(Data("{\"a\":[1,2],\"half\":[9]}".utf8)) == ["a": [1, 2]])
        #expect(throws: (any Error).self) { try MaerSyncStandsWire.decode(Data("[1,2]".utf8)) }
        #expect(throws: (any Error).self) { try MaerSyncStandsWire.decode(Data("not json".utf8)) }
    }

    @Test("die Adressen: Dokument mit und ohne Scope, Liste, Socket ueber wss, und nie ein Zeichen darin")
    func theAddresses() throws {
        let base = try #require(MaerSyncPaths.normalized(" https://sync.example.test/maer/ "))
        #expect(base.absoluteString == "https://sync.example.test/maer")
        #expect(MaerSyncPaths.document(base, kind: "stands", scope: "").absoluteString == "https://sync.example.test/maer/v1/doc/stands")
        #expect(MaerSyncPaths.document(base, kind: "claim", scope: "dev-a").absoluteString == "https://sync.example.test/maer/v1/doc/claim?scope=dev-a")
        #expect(MaerSyncPaths.listing(base, kind: "claim").absoluteString == "https://sync.example.test/maer/v1/docs/claim")
        #expect(MaerSyncPaths.changes(base)?.absoluteString == "wss://sync.example.test/maer/v1/changes")
        #expect(MaerSyncPaths.changes(try #require(MaerSyncPaths.normalized("http://tiny.local:8420")))?.absoluteString == "ws://tiny.local:8420/v1/changes")
        #expect(MaerSyncPaths.normalized("sync.example.test") == nil, "a scheme is required")
        #expect(MaerSyncPaths.normalized("ftp://sync.example.test") == nil)
        #expect(MaerSyncPaths.normalized("https://name:secret@sync.example.test") == nil, "a secret in the address is refused, not stripped")
        #expect(MaerSyncPaths.normalized("") == nil)
    }

    // MARK: - Der Topf faengt sich wieder (Nachtrag zu Build 37)

    /// Ein kaputter EINTRAG kostet seinen Eintrag, nicht den Topf. Der
    /// Hoerstand war das einzige Dokument ohne diese Eigenschaft; ein Wert
    /// vom falschen Typ warf alles weg.
    @Test("ein Eintrag vom falschen Typ kostet nur sich selbst")
    func oneEntryOfTheWrongKindCostsOnlyItself() throws {
        let wire = Data(#"{"a":[12.5,1000],"kaputt":"nicht mal eine Liste","b":[7,2000],"kurz":[3]}"#.utf8)
        let pot = try MaerSyncStandsWire.decode(wire)
        #expect(pot["a"] == [12.5, 1000])
        #expect(pot["b"] == [7, 2000])
        #expect(pot["kaputt"] == nil, "der falsche Typ kostet seinen Schluessel")
        #expect(pot["kurz"] == nil, "eine zu kurze Liste ist kein Hoerstand")
        #expect(pot.count == 2, "der Rest des Topfes ueberlebt")
    }

    /// Und die Sackgasse selbst, mit einem ABGESCHNITTENEN Dokument, nicht
    /// mit einem fremden Feld: am Dienst lag ein Koerper, der mitten in einer
    /// Zahl abbricht. Das Geraet behielt seine alte Fassung, jeder Schrieb
    /// kam als 412 zurueck, und stundenlang wurde kein Hoerstand gespeichert.
    @Test("ein abgeschnittenes Dokument sperrt das Geraet nicht aus")
    func aTruncatedDocumentDoesNotLockTheDeviceOut() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport(), announcer = FakeAnnouncer()
        // v65 gueltig, dann v66 abgeschnitten: genau die Abfolge vom Dienst.
        transport.documents[FakeTransport.key("stands", "")] =
            .init(body: Data(#"{"a":[10,1000]}"#.utf8), format: MaerSyncStandsWire.format, version: 65)
        let carrier = MaerSyncStandCarrier(session: session(transport, announcer, defaults: defaults))
        await carrier.refresh(by: "erste Runde")
        try #require(carrier.stands()["a"] != nil, "die gueltige Fassung muss angekommen sein")

        // v66: abgeschnitten mitten in einer Zahl, genau wie am Dienst.
        transport.documents[FakeTransport.key("stands", "")] =
            .init(body: Data(#"{"a":[10,1000],"b":[7,20"#.utf8), format: MaerSyncStandsWire.format, version: 66)

        carrier.write(upserts: ["c": [99, 3000]], removing: [], by: "test")
        await carrier.refresh(by: "zweite Runde")

        let held = try #require(transport.documents[FakeTransport.key("stands", "")])
        #expect(held.version > 66, "der Schrieb ist nie gelandet: das Geraet steht weiter in der Sackgasse")
        let pot = try MaerSyncStandsWire.decode(held.body)
        #expect(pot["c"] == [99, 3000], "der eigene Hoerstand fehlt am Dienst")
        #expect(pot["a"] == [10, 1000], "der Spiegel wurde weggeworfen statt behalten")
    }

    // MARK: - Der Rueckweg nach einer Abweisung

    /// Die Invariante: **kein Schrieb verschwindet lautlos.** Am Dienst
    /// gemessen (15.09.): vier Schriebe wurden mit 412 abgewiesen, drei
    /// wiederholt, die Playlisten nie. Der Grund steht hier als Fall: das
    /// Nachlesen beantwortet „hat sich das Dokument bewegt", nicht „ist mein
    /// Schrieb gelandet". Hat ein anderer Weg die Fassung schon geholt,
    /// meldet es nichts Neues, und der eigene Stand war weg.
    @Test("ein Koerper, der waehrend eines abgewiesenen Playlist-Schriebs dazukam, bleibt und geht hinaus")
    func aBodyQueuedDuringARefusedPlaylistWriteStays() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport(), announcer = FakeAnnouncer()
        transport.documents[FakeTransport.key("playlists", "")] =
            .init(body: Data("cloud".utf8), format: MaerSyncPlaylistWire.format, version: 1)
        let session = session(transport, announcer, defaults: defaults)
        await session.refresh(by: "test")
        transport.refuseNextWrite = "a newer format"
        transport.duringWrite = { [weak session] in session?.writePlaylists(Data("newer".utf8), by: "runner") }
        session.writePlaylists(Data("own".utf8), by: "test")
        await session.refresh(by: "settle")
        await session.refresh(by: "settle")
        #expect(transport.documents[FakeTransport.key("playlists", "")]?.body == Data("newer".utf8),
                "the body queued during the refused write was dropped with it")
    }

    @Test("ein Koerper, der waehrend eines veralteten Wahlen-Schriebs dazukam, bleibt und geht hinaus")
    func aBodyQueuedDuringAStaleChoicesWriteStays() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport(), announcer = FakeAnnouncer()
        transport.documents[FakeTransport.key("choices", "")] =
            .init(body: Data("cloud".utf8), format: MaerSyncChoiceWire.format, version: 1)
        let session = session(transport, announcer, defaults: defaults)
        await session.refresh(by: "test")
        transport.staleNextWrite = true
        transport.duringWrite = { [weak session] in session?.writeChoices(Data("newer".utf8), by: "runner") }
        session.writeChoices(Data("own".utf8), by: "test")
        await session.refresh(by: "settle")
        await session.refresh(by: "settle")
        #expect(transport.documents[FakeTransport.key("choices", "")]?.body == Data("newer".utf8),
                "the body queued during the stale write was dropped with it")
    }

    @Test("ein abgewiesener Playlist-Schrieb wird wiederholt, auch wenn das Nachlesen nichts Neues meldet")
    func aRefusedPlaylistWriteIsRepeatedEvenWhenTheReReadFindsNothingNew() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport(), announcer = FakeAnnouncer()
        transport.documents[FakeTransport.key("playlists", "")] =
            .init(body: Data("cloud".utf8), format: MaerSyncPlaylistWire.format, version: 1)
        let session = session(transport, announcer, defaults: defaults)
        // Diese Fassung ist schon gelesen, das Nachlesen wird also nichts
        // Neues melden. Genau die Voraussetzung, um die es geht.
        await session.refresh(by: "test")
        let readVersion = transport.documents[FakeTransport.key("playlists", "")]?.version
        try #require(readVersion == 1, "der Zeuge braucht die gelesene Fassung 1")

        var asked = 0
        session.onPlaylistsChange = { [weak session] in
            asked += 1
            // Der Laeufer verschmilzt und legt den neuen Stand hin, wie der
            // echte es tut, wenn das Ergebnis vom Dienst-Stand abweicht.
            if asked == 1 { session?.writePlaylists(Data("merged".utf8), by: "runner") }
        }

        transport.staleNextWrite = true
        session.writePlaylists(Data("own".utf8), by: "test")
        await session.refresh(by: "settle")

        #expect(asked >= 1, "der Laeufer wurde nach der Abweisung nie gefragt: der eigene Schrieb ist weg")
        let written = transport.writes.filter { $0.kind == "playlists" }
        #expect(written.count >= 2, "nach der Abweisung kam kein zweiter Versuch (\(written.count))")
        let held = transport.documents[FakeTransport.key("playlists", "")]
        #expect(held?.body == Data("merged".utf8), "der verschmolzene Stand steht nicht am Dienst")
        #expect(held.map { $0.version > 1 } == true, "die Fassung hat sich nie bewegt")
    }

    @Test("dasselbe gilt fuer die Wahlen: abgewiesen heisst wiederholt")
    func aRefusedChoicesWriteIsRepeatedToo() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport(), announcer = FakeAnnouncer()
        transport.documents[FakeTransport.key("choices", "")] =
            .init(body: Data("cloud".utf8), format: MaerSyncChoiceWire.format, version: 1)
        let session = session(transport, announcer, defaults: defaults)
        await session.refresh(by: "test")

        var asked = 0
        session.onChoicesChange = { [weak session] in
            asked += 1
            if asked == 1 { session?.writeChoices(Data("merged".utf8), by: "runner") }
        }
        transport.staleNextWrite = true
        session.writeChoices(Data("own".utf8), by: "test")
        await session.refresh(by: "settle")

        #expect(asked >= 1, "der Laeufer wurde nach der Abweisung nie gefragt")
        #expect(transport.writes.filter { $0.kind == "choices" }.count >= 2, "kein zweiter Versuch")
        #expect(transport.documents[FakeTransport.key("choices", "")]?.body == Data("merged".utf8))
    }

    /// Der Zaun ueber die KLASSE: kein `.stale`-Zweig darf seinen Rueckweg
    /// davon abhaengig machen, dass das Nachlesen eine Aenderung meldet. Die
    /// Form `if await take…(by: caller) { on…Change?() }` ist genau die, die
    /// den Schrieb verloren hat, und sie faellt hier auf, bevor sie ein
    /// drittes Mal entsteht.
    @Test("kein Schreibweg macht seinen Rueckweg von einer gemeldeten Fremdaenderung abhaengig")
    func noWritePathHangsItsRetryOnAReportedForeignChange() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let branches = source.components(separatedBy: "case .stale").dropFirst()
        try #require(branches.count >= 4, "der Sucher findet die Schreibwege nicht mehr (\(branches.count))")
        for branch in branches {
            // Nur bis zum naechsten Fall schauen, sonst faengt der Zaun den
            // ganzen Rest der Datei mit ein.
            let body = branch.components(separatedBy: "case .refused").first ?? branch
            #expect(!body.contains("if await take"),
                    "ein .stale-Zweig wiederholt nur bei gemeldeter Aenderung: \(body.prefix(120))")
        }
    }

    @Test("eine Abweisung ist ein sichtbarer Zustand, bis ein Schrieb derselben Art landet")
    func aRefusalIsVisibleUntilAWriteLands() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.refuseNextWrite = "an older format"
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        // The refresh was the next occasion and the queue went out on it;
        // the refusal it met on the way is what the page shows.
        let refusal = session.lastRefusal
        #expect(refusal == nil || refusal?.reason == "an older format")
        // The open page hears every change of the refusal through the ring,
        // the refusal from a background round and its end alike.
        var rings = 0
        session.onRefusalChange = { rings += 1 }
        transport.refuseEveryWrite = "shrank below the floor"
        carrier.write(upserts: ["rss:b:2": [5, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.lastRefusal?.kind == MaerSyncSession.standsKind)
        #expect(session.lastRefusal?.reason == "shrank below the floor")
        // A round may send more than once and each refusal is its own
        // moment, so the ring counts relatively: it rang, and it rings
        // again when the refusal ends.
        let afterRefusal = rings
        #expect(afterRefusal >= 1, "the refusal rang: \(rings)")
        transport.refuseEveryWrite = nil
        await carrier.refresh(by: "tick")
        #expect(session.lastRefusal == nil, "the write landed, the refusal is over")
        #expect(rings == afterRefusal + 1, "the end of the refusal rang once more: \(rings) after \(afterRefusal)")
    }

    // MARK: - The sign-in

    /// The platform's refusal of a plain http address (URLError -1022) is
    /// its own outcome on both buttons, never "did not answer": the service
    /// was never asked. Measured before this existed: the sign-in mapped
    /// it to `unreachable` and the page sent the person to the service.
    @Test("die Weigerung der Plattform ist ein eigener Ausgang, auf beiden Knoepfen, nie Schweigen")
    func thePlatformRefusalIsItsOwnOutcome() async {
        let refusal = URLError(.appTransportSecurityRequiresSecureConnection)
        #expect(MaerSyncSignIn.isPlatformRefusal(refusal))
        #expect(!MaerSyncSignIn.isPlatformRefusal(URLError(.cannotConnectToHost)))
        #expect(MaerSyncSignIn.outcome(forTransportError: refusal) == .plainAddressRefused)
        #expect(MaerSyncSignIn.outcome(forTransportError: URLError(.cannotConnectToHost)) == .unreachable("urlError=-1004"),
                "every other transport error stays silence with its reason")

        let transport = FakeTransport()
        transport.platformRefuses = true
        #expect(await MaerSyncSignIn.perform(address: "http://100.64.0.2:8811", owner: "owner-a", password: "s", device: "dev-a", transport: transport) == .plainAddressRefused)
        #expect(transport.tokenRequests == 0, "nothing was asked")
        #expect(await MaerSyncSignIn.test(address: "http://100.64.0.2:8811", transport: transport) == .plainAddressRefused)
        transport.platformRefuses = false
        transport.offline = true
        #expect(await MaerSyncSignIn.test(address: "http://100.64.0.2:8811", transport: transport) == .silent,
                "a service that says nothing is still silence")
    }

    @Test("die Anmeldung tauscht das Passwort nur gegen ein Zeichen, wenn der Dienst ja sagt; die Form wird vorher geprueft")
    func signInTradesTheSecretOnlyWhenTheServiceSaysYes() async {
        let transport = FakeTransport()
        // The sign-in holds the service's key on this device, so a run
        // leaves a pin behind for the address below, and the next run would
        // meet it. Cleared before and after, so each run is a first meeting.
        let pinAccount = ServiceKeyPin.account(for: URL(string: "https://sync.example.test")!)!
        KeychainStore.delete(forKey: pinAccount)
        defer { KeychainStore.delete(forKey: pinAccount) }
        #expect(await MaerSyncSignIn.perform(address: "", owner: "owner-a", password: "s", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: " ", password: "s", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "owner-a", password: "", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "sync.example.test", owner: "owner-a", password: "s", device: "dev-a", transport: transport) == .badAddress)
        #expect(transport.tokenRequests == 0, "nothing was sent for a form that is not one")

        transport.refuseToken = true
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "owner-a", password: "wrong", device: "dev-a", transport: transport) == .refused)
        transport.refuseToken = false
        transport.offline = true
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "owner-a", password: "s", device: "dev-a", transport: transport) == .unreachable("status(503)"))
        transport.offline = false

        let outcome = await MaerSyncSignIn.perform(address: " https://sync.example.test/ ", owner: " owner-a ", password: "s", device: "dev-a", transport: transport)
        #expect(outcome == .signedIn(MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token"), account: "owner-a"))
        // Two requests reached the service (the refused one and this
        // one); the offline attempt never did.
        #expect(transport.tokenRequests == 2)
        #expect(transport.lastTokenDevice == "dev-a", "the token is asked for this device")

        #expect(await MaerSyncSignIn.test(address: "nonsense", transport: transport) == .badAddress)
        #expect(await MaerSyncSignIn.test(address: "https://sync.example.test", transport: transport) == .reached)
        transport.offline = true
        #expect(await MaerSyncSignIn.test(address: "https://sync.example.test", transport: transport) == .silent)
        transport.offline = false

        // A 403 from the proxy is not "did not answer": the service stands,
        // but not from this network (LAN/mesh/VPN only). Its own sentence.
        transport.blockToken = true
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "owner-a", password: "s", device: "dev-a", transport: transport) == .blockedHere)

        // The other half of the same finding: the TEST button gave the
        // 403 the sentence of a silent service, because the health route
        // answered a Bool and a refusal looks like a no in a Bool. It says
        // what the sign-in says now, driven through the real transport call.
        transport.healthStatus = 403
        #expect(await MaerSyncSignIn.test(address: "https://sync.example.test", transport: transport) == .blockedHere)
        transport.healthStatus = 500
        #expect(await MaerSyncSignIn.test(address: "https://sync.example.test", transport: transport) == .silent,
                "a status that is neither an answer nor the proxy's refusal stays silence")
        transport.healthStatus = 200
    }

    @Test("ein Status ist noch kein Urteil: 200 erreicht, 403 aus dem falschen Netz, alles andere Schweigen")
    func statusBecomesTheSentence() {
        #expect(MaerSyncSignIn.reach(forStatus: 200) == .reached)
        #expect(MaerSyncSignIn.reach(forStatus: 403) == .blockedHere)
        #expect(MaerSyncSignIn.reach(forStatus: 404) == .silent)
        #expect(MaerSyncSignIn.reach(forStatus: 503) == .silent)
        // No response object at all is silence, not a refusal: nothing said
        // anything, so nothing may be claimed about a network.
        #expect(MaerSyncSignIn.reach(forStatus: nil) == .silent)
    }

    @Test("der Dienst waehlt seinen Takt selbst: der Topf wird jeden dritten Tick gefragt, der Anspruch schlaegt alle zehn Sekunden")
    func theServiceChoosesItsOwnCadence() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let session = session(FakeTransport(), FakeAnnouncer(), defaults: defaults)
        let stands = MaerSyncStandCarrier(session: session)
        #expect(stands.pullSeconds == 30)
        #expect(stands.sendCadenceSeconds == 60)
        let runner = PodcastCloudSync(carrier: stands)
        #expect((1...6).map { runner.pullDue(tick: $0) } == [false, false, true, false, false, true])
        #expect(MaerSyncClaimCarrier(session: session).heartbeatSeconds == 10)
    }

    @Test("die Fabriken stellen Topf und Anspruch auf den Dienst, sobald ein Zugang da ist, und sonst nicht")
    func theFactoriesChooseByAccess() {
        #expect(StandCarriers.make(access: access) is MaerSyncStandCarrier)
        #expect(!(StandCarriers.make(access: nil) is MaerSyncStandCarrier))
        #expect(ClaimCarriers.make(access: access) is MaerSyncClaimCarrier)
        #expect(ClaimCarriers.make(access: nil) is KeyValueClaimCarrier)
        // The two iCloud carriers are iCloud to the history; the door
        // carriers say so by default.
        #expect(KeyValueStandCarrier(cloud: InMemoryCloudStore(), spacingSeconds: 0).historyService == .iCloud)
    }

    @Test("die Dienst-Seite liest Schalter und Zugang; die Laeufer folgen dem Zugang, also gibt es kein Dazwischen")
    func thePageReadsTheSwitchAndTheAccess() {
        func standing(_ on: Bool, _ signedIn: Bool) -> MaerSyncStanding {
            MaerSyncStanding.standing(syncAcrossDevices: on, signedIn: signedIn)
        }
        // Der Schalter steht ueber allem: ist er aus, reist nichts, was
        // hier auch eingerichtet sein mag.
        #expect(standing(false, true) == .switchedOff)
        #expect(standing(false, false) == .switchedOff)
        #expect(standing(true, true) == .carrying)
        // Nicht angemeldet: Apple traegt, wie zuvor.
        #expect(standing(true, false) == .notInUse)
    }

    /// The dead end the answer to the position chain named: a refused token
    /// stops every round, the token stays in the keychain, and the page read
    /// "signed in" off the keychain while nothing travelled. The state is a
    /// value of the session, so the page can say it, and this is the rule
    /// the page says it by.
    @Test("ein abgewiesenes Zeichen steht auf der Seite ueber allem ausser dem Schalter, und nach der Anmeldung ist es weg")
    func aRefusedTokenIsSaidOnThePage() async {
        func standing(_ on: Bool, _ signedIn: Bool, refused: Bool) -> MaerSyncStanding {
            MaerSyncStanding.standing(syncAcrossDevices: on, signedIn: signedIn, tokenRefused: refused)
        }
        // Whatever the keychain says: refused is refused.
        #expect(standing(true, true, refused: true) == .tokenRefused)
        #expect(standing(true, false, refused: true) == .tokenRefused)
        // The switch still stands above it.
        #expect(standing(false, true, refused: true) == .switchedOff)
        // And without a refusal the states are what they were.
        #expect(standing(true, true, refused: false) == .carrying)

        // The value the page reads: set by the session on a 401, cleared
        // by the sign-in's `reloadAccess`, which is what "sign in again"
        // does. Driven through the real session over the fake transport.
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.unauthorized = true
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(standing(true, true, refused: session.unauthorized) == .tokenRefused)
        transport.unauthorized = false
        session.reloadAccess()
        #expect(standing(true, true, refused: session.unauthorized) == .carrying)
    }

    @Test("ein neuer Zugang raeumt die Abweisung: sie gehoert zum Zugang, unter dem sie kam")
    func reloadingTheAccessClearsTheRefusal() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        let session = session(transport, FakeAnnouncer(), defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: session)
        transport.refuseEveryWrite = "shrank below the floor"
        carrier.write(upserts: ["rss:b:2": [5, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.lastRefusal != nil, "the precondition: a refusal stands")
        session.reloadAccess()
        #expect(session.lastRefusal == nil, "a sign-in or sign-out reads the access again and the refusal goes with the old one")
    }
}

/// The seventh runner really runs. Until 17.09.2026 nobody started the
/// feed-auth runner from the housekeeping, and the only fence looked for a
/// string on the settings page: the page showed a code that carried nothing.
/// These witnesses drive the start way the app uses against a fake session
/// and count rounds; the source half holds that the housekeeping calls it.
struct FeedAuthStartTests {
    private let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")

    private func suite() -> (UserDefaults, String) {
        let name = "feed-auth-start-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor
    private func session(_ transport: MaerSyncCarrierTests.FakeTransport, access: MaerSyncAccess?,
                         defaults: UserDefaults) -> MaerSyncSession {
        MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                        access: { access }, deviceId: { "dev-a" }, defaults: defaults)
    }

    /// The far side is "not asked yet" until the first listing,
    /// and that listing wakes the runner even when it finds nothing.
    @Test("P4-1: vor der ersten Auflistung gilt die Gegenseite als ungefragt, die erste weckt den Laeufer auch leer, ein neuer Zugang fragt neu")
    @MainActor func theFirstListingIsWaitedFor() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let s = session(transport, access: access, defaults: defaults)
        var woken = 0
        s.feedAuthFamily.onChange = { woken += 1 }
        #expect(!s.feedAuthListed, "signed in, nothing listed: not asked yet")
        transport.offline = true
        await s.refresh(by: "witness")
        #expect(!s.feedAuthListed && woken == 0, "a failed listing is not a listing")
        transport.offline = false
        await s.refresh(by: "witness")
        #expect(s.feedAuthListed, "listed once")
        #expect(woken == 1, "the first listing wakes the runner although it found nothing")
        await s.refresh(by: "witness")
        #expect(woken == 1, "a later listing that finds nothing new stays quiet")
        s.reloadAccess()
        #expect(!s.feedAuthListed, "a new access asks the far side again")
    }

    @Test("mit Zugang startet der Laeufer aus dem Haushalt und faehrt genau eine Runde; eine Aenderung danach eine weitere")
    @MainActor func startsWithAnAccessAndRunsOneRound() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let runner = FeedAuthSync(syncEnabled: { true })
        #expect(runner.rounds == 0)
        runner.startIfConfigured(session: session(MaerSyncCarrierTests.FakeTransport(), access: access, defaults: defaults),
                                 by: "witness")
        #expect(runner.started, "the runner must be started by the housekeeping's way")
        #expect(runner.rounds == 1, "exactly one round at the start")
        // The former string fence, lifted to behaviour: a local change
        // after the start (an adopted code) runs a round at once.
        _ = runner.noteLocalChange(by: "witness")
        #expect(runner.rounds == 2, "a local change runs a round at once")
        // A second start (the switch turned on again) nudges a round, like
        // the six others, instead of doing nothing.
        runner.startIfConfigured(session: session(MaerSyncCarrierTests.FakeTransport(), access: access, defaults: defaults),
                                 by: "switch")
        #expect(runner.rounds == 3, "a second start nudges a round")
    }

    /// The switch is asked on every round: turned off after the start, the
    /// runner writes nothing more, and turned on again it runs again.
    @Test("der Schalter gilt je Runde: aus nach dem Start schreibt keine Runde mehr, an wieder")
    @MainActor func theSwitchHoldsEveryRound() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        var on = true
        let transport = MaerSyncCarrierTests.FakeTransport()
        let runner = FeedAuthSync(syncEnabled: { on })
        runner.startIfConfigured(session: session(transport, access: access, defaults: defaults), by: "witness")
        #expect(runner.started && runner.rounds == 1, "the precondition: started and one round")
        let writesBefore = transport.writes.count
        on = false
        _ = runner.noteLocalChange(by: "witness")
        runner.startIfConfigured(session: session(transport, access: access, defaults: defaults), by: "switch")
        #expect(runner.rounds == 1, "with the switch off no round runs")
        #expect(transport.writes.count == writesBefore, "and nothing is written")
        on = true
        _ = runner.noteLocalChange(by: "witness")
        #expect(runner.rounds == 2, "on again: a round runs")
    }

    @Test("ohne Zugang oder mit dem Schalter aus: kein Start, keine Runde, nichts geschrieben")
    @MainActor func withoutAnAccessNothingRuns() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let runner = FeedAuthSync(syncEnabled: { true })
        runner.startIfConfigured(session: session(transport, access: nil, defaults: defaults), by: "witness")
        #expect(!runner.started, "without an access there is nothing to run on")
        _ = runner.noteLocalChange(by: "witness")
        #expect(runner.rounds == 0, "no round without a session")
        #expect(transport.writes.isEmpty, "nothing written without a session")
        let off = FeedAuthSync(syncEnabled: { false })
        off.startIfConfigured(session: session(MaerSyncCarrierTests.FakeTransport(), access: access, defaults: defaults),
                              by: "witness")
        #expect(!off.started, "the switch off keeps the runner off, like the six others")
        #expect(off.rounds == 0)
    }

    /// The second start site: the switch's onChange names this runner
    /// beside the five it starts, so a switch turned on after the start
    /// reaches it.
    @Test("der Schalter startet den Laeufer neben den fuenf anderen")
    func theSwitchStartsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Views/SettingsView.swift"), encoding: .utf8)
        let start = try #require(text.range(of: ".onChange(of: podcastICloudSync)"))
        let body = String(text[start.upperBound...].prefix(900)).components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(body.contains("FeedAuthSync.shared.startIfConfigured(by:\"switch\")"), "the switch does not start FeedAuthSync")
        #expect(body.contains("PlaybackClaimSync.shared.start()"), "the five others are still there")
    }

    /// The source half: the housekeeping's runner list names this start.
    /// Taking the call out must tear here with the runner's name.
    @Test("der Haushalt startet den Laeufer neben den sechs anderen")
    func theHousekeepingStartsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/AppHousekeeping.swift"),
                              encoding: .utf8)
        let start = try #require(text.range(of: "func startServices()"))
        let body = text[start.upperBound...]
        let end = body.range(of: "static func")?.lowerBound ?? body.endIndex
        let services = String(body[..<end]).components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(services.contains("FeedAuthSync.shared.startIfConfigured("),
                "startServices does not start FeedAuthSync")
        #expect(services.contains("PlaybackClaimSync.shared.start()"), "the six others are still there")
    }
}
#endif
