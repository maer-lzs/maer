// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// S3: the feed credentials are sealed with the account's feed key, not a
/// device code. Two devices of one account need no code between them, a
/// device without the feed key goes on as before, and the code goes once
/// the own block sealed with the feed key stands.
@MainActor
struct FeedKeySealingTests {
    static let codeX = DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB")!
    static let codeY = DeviceLinkCode.normalized("BCDE-FGHJ-KMNP-QRST-VWXY-ZABC")!
    static let feedK = Data((0..<32).map { UInt8($0) })
    static let feedOther = Data((0..<32).map { UInt8(255 - $0) })

    static func entry(_ user: String, at: Double) -> FeedAuthBlock.Entry {
        FeedAuthBlock.Entry(credentials: .init(user: user, password: "geheim-\(user)"), at: at)
    }

    // MARK: - The envelope

    @Test("S3: Umschlag 2 oeffnet mit demselben Feed-Schluessel, mit einem anderen nicht, ohne keinen; Umschlag 1 wie vorher")
    func theFeedEnvelope() throws {
        let plain = Data("geheim".utf8)
        let sealed = try #require(FeedAuthCrypto.seal(plain, feed: Self.feedK))
        #expect(FeedAuthCrypto.version(of: sealed) == 2)
        #expect(FeedAuthCrypto.open(sealed, code: nil, feed: Self.feedK) == .plaintext(plain))
        #expect(FeedAuthCrypto.open(sealed, code: Self.codeX, feed: Self.feedOther) == .sealedForAnother)
        #expect(FeedAuthCrypto.open(sealed, code: Self.codeX, feed: nil) == .sealedForAnother,
                "a device without the feed key cannot read it and does not pretend to")
        let old = try #require(FeedAuthCrypto.seal(plain, code: Self.codeX))
        #expect(FeedAuthCrypto.version(of: old) == 1)
        #expect(FeedAuthCrypto.open(old, code: Self.codeX, feed: Self.feedK) == .plaintext(plain))
        #expect(FeedAuthCrypto.open(old, code: nil, feed: Self.feedK) == .sealedForAnother)
        let future = try JSONSerialization.data(withJSONObject: ["v": 3])
        #expect(FeedAuthCrypto.open(future, code: Self.codeX, feed: Self.feedK) == .newerFormat(3))
        #expect(FeedAuthCrypto.format == 1, "the document format on the wire does not move")
    }

    // MARK: - The rule

    @Test("S3: mit Feed-Schluessel zaehlt ein ungeoeffneter Code-Block nicht, ein ungeoeffneter Feed-Block schon; ohne alles wie vorher")
    func whatCounts() {
        #expect(!FeedAuthRound.counts(envelope: 1, opening: .sealedForAnother, hasFeed: true))
        #expect(FeedAuthRound.counts(envelope: 1, opening: .plaintext(Data()), hasFeed: true), "an opened one is read")
        #expect(FeedAuthRound.counts(envelope: 2, opening: .sealedForAnother, hasFeed: true), "another password")
        #expect(FeedAuthRound.counts(envelope: 1, opening: .sealedForAnother, hasFeed: false), "no feed key: as before")
        #expect(FeedAuthRound.counts(envelope: nil, opening: .unreadable, hasFeed: true))
        #expect(FeedAuthRound.writes(hasFeed: true) == 2 && FeedAuthRound.writes(hasFeed: false) == 1)
        #expect(FeedAuthRound.mayForgetCode(hasFeed: true, hasCode: true, ownFeedBlockStands: true))
        #expect(!FeedAuthRound.mayForgetCode(hasFeed: false, hasCode: true, ownFeedBlockStands: true),
                "without the feed key the code stays")
        #expect(!FeedAuthRound.mayForgetCode(hasFeed: true, hasCode: true, ownFeedBlockStands: false),
                "not before the own sealed block stands")
    }

    // MARK: - Two devices against one service

    /// One device's keychain, in memory.
    final class Keychain {
        var code: String?
        var feed: Data?
        var mine: [String: FeedAuthBlock.Entry]
        init(code: String?, feed: Data?, mine: [String: FeedAuthBlock.Entry]) {
            self.code = code; self.feed = feed; self.mine = mine
        }
        var keys: FeedAuthSync.Keys {
            FeedAuthSync.Keys(code: { self.code }, forgetCode: { self.code = nil }, feed: { _ in self.feed },
                              mine: { self.mine }, apply: { merged, _ in self.mine = merged })
        }
    }

    static let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")

    static func device(_ id: String, _ transport: MaerSyncCarrierTests.FakeTransport,
                       _ keychain: Keychain) -> (MaerSyncSession, FeedAuthSync, UserDefaults, String) {
        let name = "feed-key-\(id)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { id }, defaults: defaults)
        return (session, FeedAuthSync(syncEnabled: { true }, keys: keychain.keys), defaults, name)
    }

    static func envelopes(_ transport: MaerSyncCarrierTests.FakeTransport) -> [String: Int?] {
        var found: [String: Int?] = [:]
        for (key, stored) in transport.documents where key.hasPrefix(MaerSyncSession.feedAuthKind + "|") {
            found[String(key.dropFirst(MaerSyncSession.feedAuthKind.count + 1))] = FeedAuthCrypto.version(of: stored.body)
        }
        return found
    }

    @Test("S3: die gemessene Lage, Telefon mit Zugaengen und Code X, Tablet leer mit Code Y und altem Block; nach den Runden tragen beide die Zugaenge, kein Block der Fassung 1 bleibt, beide Codes sind vergessen")
    func twoDevicesOneService() async throws {
        let transport = MaerSyncCarrierTests.FakeTransport()
        // The iPad's old block: empty, sealed with its own code Y, as the
        // log of 24.09. shows it writing.
        let emptyBlock = try #require(FeedAuthBlock.encode([:]))
        let oldPad = try #require(FeedAuthCrypto.seal(emptyBlock, code: Self.codeY))
        transport.documents[MaerSyncCarrierTests.FakeTransport.key(MaerSyncSession.feedAuthKind, "dev-pad")] =
            .init(body: oldPad, format: FeedAuthCrypto.format, version: 1)
        let phoneKeys = Keychain(code: Self.codeX, feed: Self.feedK, mine: ["a": Self.entry("anna", at: 1000)])
        let padKeys = Keychain(code: Self.codeY, feed: Self.feedK, mine: [:])
        let (phoneSession, phone, d1, n1) = Self.device("dev-phone", transport, phoneKeys)
        let (padSession, pad, d2, n2) = Self.device("dev-pad", transport, padKeys)
        defer { d1.removePersistentDomain(forName: n1); d2.removePersistentDomain(forName: n2) }

        phone.start(session: phoneSession, by: "witness")
        pad.start(session: padSession, by: "witness")
        for _ in 0..<3 {
            await phoneSession.refresh(by: "witness")
            await padSession.refresh(by: "witness")
        }
        // One more round each, the one in which the code may go.
        _ = phone.noteLocalChange(by: "witness")
        _ = pad.noteLocalChange(by: "witness")

        #expect(phoneKeys.mine["a"]?.credentials.user == "anna", "the phone keeps its credentials")
        #expect(padKeys.mine["a"]?.credentials.user == "anna", "the pad carries the phone's credentials")
        #expect(Self.envelopes(transport) == ["dev-phone": 2, "dev-pad": 2], "no block of envelope 1 stays written")
        #expect(phoneKeys.code == nil && padKeys.code == nil, "both codes are forgotten")
    }

    // MARK: - Rest

    /// The feed-block writes of one device so far.
    static func feedWrites(_ transport: MaerSyncCarrierTests.FakeTransport, _ device: String) -> Int {
        transport.writes.filter { $0.kind == MaerSyncSession.feedAuthKind && $0.scope == device }.count
    }

    @Test("TF-1: eine Runde schreibt nur, wenn Inhalt oder Umschlag vom stehenden eigenen Block abweichen, geoeffnet verglichen")
    func onlyAChangedContentWrites() {
        let same = ["a": Self.entry("anna", at: 1000)]
        #expect(!FeedAuthRound.mustPutUp(same, envelope: 2, standing: same, standingEnvelope: 2),
                "the same content under the same envelope stands already")
        #expect(FeedAuthRound.mustPutUp(same, envelope: 2, standing: [:], standingEnvelope: 2), "new content goes up")
        #expect(FeedAuthRound.mustPutUp(same, envelope: 2, standing: same, standingEnvelope: 1),
                "the same content under the old envelope is sealed anew")
        #expect(FeedAuthRound.mustPutUp(same, envelope: 2, standing: nil, standingEnvelope: nil), "nothing stands yet")
    }

    @Test("TF-1: zwei Geraete mit Feed-Schluessel und gleichem Inhalt werden still; nach dem Einschwingen null Schreibvorgaenge in zwanzig Runden")
    func twoDevicesComeToRest() async throws {
        let transport = MaerSyncCarrierTests.FakeTransport()
        let phoneKeys = Keychain(code: nil, feed: Self.feedK, mine: [:])
        let padKeys = Keychain(code: nil, feed: Self.feedK, mine: [:])
        let (phoneSession, phone, d1, n1) = Self.device("dev-phone", transport, phoneKeys)
        let (padSession, pad, d2, n2) = Self.device("dev-pad", transport, padKeys)
        defer { d1.removePersistentDomain(forName: n1); d2.removePersistentDomain(forName: n2) }

        phone.start(session: phoneSession, by: "witness")
        pad.start(session: padSession, by: "witness")
        for _ in 0..<3 {
            await phoneSession.refresh(by: "witness")
            await padSession.refresh(by: "witness")
        }
        await phoneSession.refresh(by: "witness")
        await padSession.refresh(by: "witness")
        let settled = (Self.feedWrites(transport, "dev-phone"), Self.feedWrites(transport, "dev-pad"))
        #expect(settled.0 >= 1 && settled.1 >= 1, "each device put its block up once to begin with")
        // Twenty change rounds on each side: every refresh brings the other
        // device's version, and every local note asks for a round.
        for _ in 0..<20 {
            await phoneSession.refresh(by: "witness")
            await padSession.refresh(by: "witness")
            _ = phone.noteLocalChange(by: "change")
            _ = pad.noteLocalChange(by: "change")
        }
        await phoneSession.refresh(by: "witness")
        await padSession.refresh(by: "witness")
        #expect(Self.feedWrites(transport, "dev-phone") == settled.0, "the phone keeps writing its unchanged block")
        #expect(Self.feedWrites(transport, "dev-pad") == settled.1, "the pad keeps writing its unchanged block")
    }

    @Test("TF-1: mit einem Eintrag auf einer Seite schreibt nach der Uebernahme jedes Geraet hoechstens einmal, dann Ruhe")
    func oneEntryOneMoreWriteEach() async throws {
        let transport = MaerSyncCarrierTests.FakeTransport()
        let phoneKeys = Keychain(code: nil, feed: Self.feedK, mine: ["a": Self.entry("anna", at: 1000)])
        let padKeys = Keychain(code: nil, feed: Self.feedK, mine: [:])
        let (phoneSession, phone, d1, n1) = Self.device("dev-phone", transport, phoneKeys)
        let (padSession, pad, d2, n2) = Self.device("dev-pad", transport, padKeys)
        defer { d1.removePersistentDomain(forName: n1); d2.removePersistentDomain(forName: n2) }

        phone.start(session: phoneSession, by: "witness")
        pad.start(session: padSession, by: "witness")
        var rounds = 0
        while padKeys.mine["a"] == nil && rounds < 5 {
            await phoneSession.refresh(by: "witness")
            await padSession.refresh(by: "witness")
            rounds += 1
        }
        try #require(padKeys.mine["a"]?.credentials.user == "anna", "the pad took the phone's credentials over")
        let takenOver = (Self.feedWrites(transport, "dev-phone"), Self.feedWrites(transport, "dev-pad"))
        for _ in 0..<20 {
            await phoneSession.refresh(by: "witness")
            await padSession.refresh(by: "witness")
            _ = phone.noteLocalChange(by: "change")
            _ = pad.noteLocalChange(by: "change")
        }
        await phoneSession.refresh(by: "witness")
        await padSession.refresh(by: "witness")
        #expect(Self.feedWrites(transport, "dev-phone") - takenOver.0 <= 1, "the phone wrote on after the takeover")
        #expect(Self.feedWrites(transport, "dev-pad") - takenOver.1 <= 1, "the pad wrote on after the takeover")
    }

    @Test("S3: der alte Code-Block eines Geraets, das nie wiederkommt, haelt den Feed-Schluessel nicht zurueck")
    func aStaleCodeBlockDoesNotHoldBack() async throws {
        let transport = MaerSyncCarrierTests.FakeTransport()
        let emptyBlock = try #require(FeedAuthBlock.encode([:]))
        let gone = try #require(FeedAuthCrypto.seal(emptyBlock, code: Self.codeY))
        transport.documents[MaerSyncCarrierTests.FakeTransport.key(MaerSyncSession.feedAuthKind, "dev-gone")] =
            .init(body: gone, format: FeedAuthCrypto.format, version: 1)
        let keys = Keychain(code: Self.codeX, feed: Self.feedK, mine: ["a": Self.entry("anna", at: 1000)])
        let (session, runner, defaults, name) = Self.device("dev-phone", transport, keys)
        defer { defaults.removePersistentDomain(forName: name) }
        runner.start(session: session, by: "witness")
        for _ in 0..<3 { await session.refresh(by: "witness") }
        #expect(Self.envelopes(transport)["dev-phone"] == 2,
                "a block sealed with another code splits nothing when this device writes with the feed key")
        #expect(runner.block != .sealedForAnother)
    }

    @Test("S3: ein Geraet ohne Feed-Schluessel versiegelt nichts neu und vergisst seinen Code nicht")
    func withoutTheFeedKeyNothingChanges() async throws {
        let transport = MaerSyncCarrierTests.FakeTransport()
        let keys = Keychain(code: Self.codeX, feed: nil, mine: ["a": Self.entry("anna", at: 1000)])
        let (session, runner, defaults, name) = Self.device("dev-old", transport, keys)
        defer { defaults.removePersistentDomain(forName: name) }
        runner.start(session: session, by: "witness")
        for _ in 0..<3 { await session.refresh(by: "witness") }
        _ = runner.noteLocalChange(by: "witness")
        #expect(Self.envelopes(transport) == ["dev-old": 1], "sealed with its code, as before")
        #expect(keys.code == Self.codeX, "the code stays")
    }

    @Test("S3: die App liest ihre Schluessel an der Tuer des Geraets, die Seite hat keinen Code mehr")
    func theDeviceWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Networking/FeedAuthSync.swift"), encoding: .utf8)
        let flat = SyncContractFenceTests.stripped(runner).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("static let shared = AccessFollowers.enrolled(FeedAuthSync())"), "the app's runner takes the device's keys")
        #expect(flat.contains("keys: Keys = .device"))
        #expect(flat.contains("feed: { FeedKeyStore.held(for: $0) }"))
        #expect(flat.contains("Logger.library.notice(\"FEEDKEY held=\\(held ? \"yes\" : \"no\", privacy: .public)\")"),
                "the log says whether the key is held, never the key")
    }
}
#endif
