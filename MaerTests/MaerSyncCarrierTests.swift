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
        /// Every write is refused with this sentence while it is set.
        var refuseEveryWrite: String?
        var unauthorized = false
        var offline = false
        var refuseToken = false
        /// The proxy answers 403: the service stands, but not from here.
        var blockToken = false
        var tokenRequests = 0
        var lastTokenDevice = ""

        nonisolated static func key(_ kind: String, _ scope: String) -> String { "\(kind)|\(scope)" }

        func fetch(kind: String, scope: String, access: MaerSyncAccess) async throws -> MaerSyncDocument? {
            try gate()
            fetches.append(Self.key(kind, scope))
            guard let held = documents[Self.key(kind, scope)] else { return nil }
            return MaerSyncDocument(body: held.body, format: held.format, etag: String(held.version))
        }

        func write(kind: String, scope: String, body: Data, format: Int, ifMatch: String?,
                   declaredShrink: Bool, access: MaerSyncAccess) async throws -> MaerSyncWriteOutcome {
            try gate()
            writes.append(Write(kind: kind, scope: scope, ifMatch: ifMatch, declared: declaredShrink, bytes: body.count))
            if let reason = refuseNextWrite {
                refuseNextWrite = nil
                return .refused(reason: reason)
            }
            if let reason = refuseEveryWrite { return .refused(reason: reason) }
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

        func token(owner: String, secret: String, device: String, at baseURL: URL) async throws -> String {
            try gate()
            tokenRequests += 1
            lastTokenDevice = device
            if refuseToken { throw MaerSyncFailure.unauthorized }
            if blockToken { throw MaerSyncFailure.status(403) }
            return "a-token"
        }

        func health(at baseURL: URL) async throws -> Bool {
            try gate()
            return true
        }

        private func gate() throws {
            if unauthorized { throw MaerSyncFailure.unauthorized }
            if offline { throw MaerSyncFailure.status(503) }
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
        var onClose: (@MainActor () -> Void)?

        func open(access: MaerSyncAccess,
                  onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
                  onClose: @escaping @MainActor () -> Void) {
            opens += 1
            isOpen = true
            self.onAnnouncement = onAnnouncement
            self.onClose = onClose
        }

        func close() {
            if isOpen { closes += 1 }
            isOpen = false
        }

        func announce(_ announcement: MaerSyncAnnouncement) { onAnnouncement?(announcement) }

        /// The socket died under the session.
        func drop() {
            isOpen = false
            onClose?()
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

    @Test("ein unlesbarer Topf ersetzt den Spiegel nicht, und der naechste Schrieb ueberschreibt ihn nicht")
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
        #expect(transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")]?.body == Data("not a pot".utf8),
                "a write over what was never read is a stale write, and stays one")
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
        transport.refuseEveryWrite = "shrank below the floor"
        carrier.write(upserts: ["rss:b:2": [5, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(session.lastRefusal?.kind == MaerSyncSession.standsKind)
        #expect(session.lastRefusal?.reason == "shrank below the floor")
        transport.refuseEveryWrite = nil
        await carrier.refresh(by: "tick")
        #expect(session.lastRefusal == nil, "the write landed, the refusal is over")
    }

    // MARK: - The sign-in

    @Test("die Anmeldung tauscht das Passwort nur gegen ein Zeichen, wenn der Dienst ja sagt; die Form wird vorher geprueft")
    func signInTradesTheSecretOnlyWhenTheServiceSaysYes() async {
        let transport = FakeTransport()
        #expect(await MaerSyncSignIn.perform(address: "", owner: "the-owner", secret: "s", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: " ", secret: "s", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "the-owner", secret: "", device: "dev-a", transport: transport) == .missing)
        #expect(await MaerSyncSignIn.perform(address: "sync.example.test", owner: "the-owner", secret: "s", device: "dev-a", transport: transport) == .badAddress)
        #expect(transport.tokenRequests == 0, "nothing was sent for a form that is not one")

        transport.refuseToken = true
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "the-owner", secret: "wrong", device: "dev-a", transport: transport) == .refused)
        transport.refuseToken = false
        transport.offline = true
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "the-owner", secret: "s", device: "dev-a", transport: transport) == .unreachable("status(503)"))
        transport.offline = false

        let outcome = await MaerSyncSignIn.perform(address: " https://sync.example.test/ ", owner: " the-owner ", secret: "s", device: "dev-a", transport: transport)
        #expect(outcome == .signedIn(MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token"), account: "the-owner"))
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
        #expect(await MaerSyncSignIn.perform(address: "https://sync.example.test", owner: "the-owner", secret: "s", device: "dev-a", transport: transport) == .blockedHere)
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
}
#endif
