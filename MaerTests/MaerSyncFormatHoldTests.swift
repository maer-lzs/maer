// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A 409 for a document written in a newer form: the kind rests until a
/// build reads that form, instead of writing again on every occasion. After
/// a 409 the carrier asks for the document once; its `X-Maer-Format` says
/// which gate refused. A form not newer is the gate of a shrink, as before.
@MainActor
struct MaerSyncFormatHoldTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    private let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
    private let olderForm = "written at a newer format"

    private func suite() -> (UserDefaults, String) {
        let name = "format-hold-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func session(_ transport: FakeTransport, defaults: UserDefaults,
                         ownFormats: [String: Int]? = nil) -> MaerSyncSession {
        MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                        access: { access }, deviceId: { "dev-a" }, defaults: defaults,
                        ownFormats: ownFormats)
    }

    /// The stands of another device, in a form this build does not read.
    private func newerStands(_ transport: FakeTransport) throws {
        transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")] =
            .init(body: try MaerSyncStandsWire.encode(["rss:x:1": [5, 500]]), format: MaerSyncStandsWire.format + 1, version: 1)
    }

    private func writes(_ transport: FakeTransport, _ kind: String) -> Int {
        transport.writes.filter { $0.kind == kind }.count
    }

    @Test("the rule reads the vectors the other platforms take byte for byte", .needsTheSources)
    func theRuleFollowsTheVectors() throws {
        let url = SourceTree.root.appendingPathComponent("MaerTests/Fixtures/MaerSyncFormatHold/vektoren.json")
        let table = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(table["faelle"] as? [[String: Any]])
        #expect(cases.count == 6)
        for item in cases {
            let own = try #require(item["eigene"] as? Int)
            let stored = item["gespeicherte"] as? Int
            let rests = try #require(item["ruht"] as? Bool)
            #expect(MaerSyncFormatHold.rests(own: own, stored: stored) == rests, "\(item)")
        }
    }

    @Test("a refusal at a newer form lets the stands rest: no write on the next occasions")
    func aRefusalAtANewerFormHoldsTheKind() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: s)
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(s.formatHolds[MaerSyncSession.standsKind] == MaerSyncStandsWire.format + 1, "the stands do not rest")
        let first = writes(transport, MaerSyncSession.standsKind)
        #expect(first <= 1)
        for i in 0..<5 {
            carrier.write(upserts: ["rss:a:\(i + 2)": [Double(i), 2_000]], removing: [], by: "witness")
            await carrier.refresh(by: "witness")
        }
        #expect(writes(transport, MaerSyncSession.standsKind) == first, "the resting stands wrote on an occasion")
    }

    @Test("a refusal that is the gate of a shrink lets nothing rest, as before")
    func aRefusalThatIsAShrinkDoesNotHold() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.refuseEveryWrite = "shrank below the floor"
        let s = session(transport, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: s)
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        let first = writes(transport, MaerSyncSession.standsKind)
        carrier.write(upserts: ["rss:a:2": [100, 2_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(s.formatHolds.isEmpty)
        #expect(writes(transport, MaerSyncSession.standsKind) > first, "a shrink refusal stopped the writes")
        #expect(s.lastRefusal?.kind == MaerSyncSession.standsKind)
    }

    @Test("the rest outlasts a launch, and the page reads its refusal sentence")
    func theHoldOutlastsALaunch() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        transport.refuseEveryWrite = olderForm
        let before = MaerSyncStandCarrier(session: session(transport, defaults: defaults))
        before.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await before.refresh(by: "witness")
        let written = writes(transport, MaerSyncSession.standsKind)

        let s = session(transport, defaults: defaults)
        #expect(s.formatHolds[MaerSyncSession.standsKind] != nil, "the rest did not outlast the launch")
        #expect(s.lastRefusal?.kind == MaerSyncSession.standsKind, "the page has no line for the resting kind")
        #expect(s.lastRefusal?.reason == olderForm, "the line is not the refusal sentence")
        let after = MaerSyncStandCarrier(session: s)
        after.write(upserts: ["rss:a:2": [100, 2_000]], removing: [], by: "witness")
        await after.refresh(by: "witness")
        #expect(writes(transport, MaerSyncSession.standsKind) == written, "the resting stands wrote after a launch")
    }

    @Test("a build that reads the form ends the rest and sends what waited, in one write")
    func aBuildThatReadsTheFormLifts() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        transport.refuseEveryWrite = olderForm
        let resting = session(transport, defaults: defaults)
        let before = MaerSyncStandCarrier(session: resting)
        before.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await before.refresh(by: "witness")
        before.write(upserts: ["rss:a:2": [100, 2_000]], removing: [], by: "witness")
        await before.refresh(by: "witness")
        try #require(resting.formatHolds[MaerSyncSession.standsKind] != nil, "the stands never rested")
        transport.refuseEveryWrite = nil
        let written = writes(transport, MaerSyncSession.standsKind)

        let s = session(transport, defaults: defaults,
                        ownFormats: [MaerSyncSession.standsKind: MaerSyncStandsWire.format + 1])
        #expect(s.formatHolds.isEmpty, "the build that reads the form still rests")
        await MaerSyncStandCarrier(session: s).refresh(by: "witness")
        #expect(writes(transport, MaerSyncSession.standsKind) == written + 1)
        let stored = try transport.stands()
        #expect(stored["rss:a:1"] != nil && stored["rss:a:2"] != nil, "what waited did not go out")
    }

    @Test("what is noted while the kind rests waits, and goes out once the document is gone")
    func theQueueIsKeptWhileHeld() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: s)
        for i in 0..<3 {
            carrier.write(upserts: ["rss:q:\(i)": [Double(i), 1_000]], removing: [], by: "witness")
            await carrier.refresh(by: "witness")
        }
        try #require(s.formatHolds[MaerSyncSession.standsKind] != nil, "the stands never rested")
        transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")] = nil
        transport.refuseEveryWrite = nil
        await carrier.refresh(by: "witness")
        await carrier.refresh(by: "witness")
        let stored = try transport.stands()
        #expect(Set(stored.keys).isSuperset(of: ["rss:q:0", "rss:q:1", "rss:q:2"]), "what waited was lost")
    }

    /// The page says "the service refused a write", so the rest begins at
    /// the refusal, not at the fetch: the fetch takes the version and none
    /// of the body, and the next write meets the gate of the form.
    @Test("a document in a newer form is not taken, and the next write's refusal starts the rest")
    func aFetchAtANewerFormTakesNothing() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        let s = session(transport, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: s)
        await carrier.refresh(by: "witness")
        #expect(carrier.stands()["rss:x:1"] == nil, "a document in a newer form was read as this build's")
        transport.refuseEveryWrite = olderForm
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        #expect(transport.writes.last?.ifMatch == "1", "the write did not name the version of the newer document")
        #expect(s.formatHolds[MaerSyncSession.standsKind] == MaerSyncStandsWire.format + 1)
        #expect(s.lastRefusal?.reason == olderForm)
    }

    @Test("a document gone, or in a form not newer, ends the rest")
    func aDocumentGoneOrOlderLifts() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        try newerStands(transport)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        let carrier = MaerSyncStandCarrier(session: s)
        carrier.write(upserts: ["rss:a:1": [100, 1_000]], removing: [], by: "witness")
        await carrier.refresh(by: "witness")
        try #require(s.formatHolds[MaerSyncSession.standsKind] != nil)
        transport.documents[FakeTransport.key(MaerSyncSession.standsKind, "")] =
            .init(body: try MaerSyncStandsWire.encode(["rss:x:1": [5, 500]]), format: MaerSyncStandsWire.format, version: 2)
        await carrier.refresh(by: "witness")
        #expect(s.formatHolds.isEmpty, "a document in this build's form did not end the rest")
    }

    @Test("the playlists rest the same way")
    func thePlaylistsRest() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.documents[FakeTransport.key(MaerSyncSession.playlistsKind, "")] =
            .init(body: Data("later".utf8), format: MaerSyncPlaylistWire.format + 1, version: 1)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        for i in 0..<3 {
            s.writePlaylists(Data("own \(i)".utf8), by: "witness")
            await s.refresh(by: "witness")
        }
        #expect(writes(transport, MaerSyncSession.playlistsKind) <= 1, "the resting playlists wrote again")
        #expect(s.formatHolds[MaerSyncSession.playlistsKind] != nil)
    }

    @Test("the choices rest the same way")
    func theChoicesRest() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.documents[FakeTransport.key(MaerSyncSession.choicesKind, "")] =
            .init(body: Data("later".utf8), format: MaerSyncChoiceWire.format + 1, version: 1)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        for i in 0..<3 {
            s.writeChoices(Data("own \(i)".utf8), by: "witness")
            await s.refresh(by: "witness")
        }
        #expect(writes(transport, MaerSyncSession.choicesKind) <= 1, "the resting choices wrote again")
        #expect(s.formatHolds[MaerSyncSession.choicesKind] != nil)
    }

    @Test("a family with a scope rests the same way")
    func aScopedFamilyRests() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.documents[FakeTransport.key(MaerSyncSession.statsKind, "dev-a")] =
            .init(body: Data("later".utf8), format: MaerSyncStatsWire.format + 1, version: 1)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        for i in 0..<3 {
            s.writeStats(Data("own \(i)".utf8), deviceId: "dev-a", by: "witness")
            await s.refresh(by: "witness")
        }
        #expect(writes(transport, MaerSyncSession.statsKind) == 1, "the resting statistics wrote again")
        #expect(s.formatHolds[MaerSyncSession.statsKind] != nil)
    }

    @Test("a rest asks for the document once, not on every occasion")
    func theHoldAsksOnce() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = FakeTransport()
        transport.documents[FakeTransport.key(MaerSyncSession.statsKind, "dev-a")] =
            .init(body: Data("later".utf8), format: MaerSyncStatsWire.format + 1, version: 1)
        transport.refuseEveryWrite = olderForm
        let s = session(transport, defaults: defaults)
        s.writeStats(Data("own".utf8), deviceId: "dev-a", by: "witness")
        await s.refresh(by: "witness")
        let asked = transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.statsKind, "dev-a") }.count
        #expect(asked == 1, "the refusal did not ask for the document once: \(asked)")
        try #require(s.formatHolds[MaerSyncSession.statsKind] != nil, "the statistics never rested")
        for i in 0..<4 {
            s.writeStats(Data("own \(i)".utf8), deviceId: "dev-a", by: "witness")
            await s.refresh(by: "witness")
        }
        #expect(transport.fetches.filter { $0 == FakeTransport.key(MaerSyncSession.statsKind, "dev-a") }.count == asked,
                "the rest asked again on an occasion")
    }

    @Test("every refused write goes through the one rule, and no write path passes a rest", .needsTheSources)
    func everyRefusalGoesThroughTheRule() throws {
        let source = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"))
        let refusals = source.components(separatedBy: "case .refused(let reason):").dropFirst()
        #expect(refusals.count == 4, "the fence finds \(refusals.count) refusals")
        for branch in refusals {
            let body = branch.components(separatedBy: "} catch {").first ?? branch
            #expect(body.contains("await restsAfterRefusal("), "a refusal passes the rule: \(body.prefix(100))")
        }
        for send in ["private func sendStands(", "private func sendPlaylists(", "private func sendChoices(",
                     "private func send(_ family: ScopedFamily"] {
            let body = source.components(separatedBy: send).dropFirst().first ?? ""
            let head = body.components(separatedBy: "while generation").first ?? body
            #expect(head.contains("formatHolds["), "\(send) writes past a rest")
        }
    }

    @Test("the own forms are those of the wires unless a witness hands others in")
    func theOwnFormsAreTheWires() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let s = session(FakeTransport(), defaults: defaults)
        #expect(s.ownFormats[MaerSyncSession.standsKind] == MaerSyncStandsWire.format)
        #expect(s.ownFormats[MaerSyncSession.playlistsKind] == MaerSyncPlaylistWire.format)
        #expect(s.ownFormats[MaerSyncSession.choicesKind] == MaerSyncChoiceWire.format)
        #expect(s.ownFormats[MaerSyncSession.statsKind] == MaerSyncStatsWire.format)
        #expect(s.ownFormats[MaerSyncSession.claimKind] == MaerSyncClaimWire.format)
        #expect(s.ownFormats[MaerSyncSession.feedAuthKind] == FeedAuthCrypto.format)
    }
}
#endif
