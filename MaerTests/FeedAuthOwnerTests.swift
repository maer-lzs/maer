// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The feed credentials follow the account (decision of 03.10.2026, a new
/// beginning): at a switch the holder's credentials rest in the keychain
/// under its name with the live item's attributes, read back before
/// anything is replaced; the shelf holds only hashes and moments; the new
/// account's block carries nothing of the holder, sealed with the feed key
/// or with the code; and the way back brings the holder's credential back,
/// also without a second device.
@MainActor
struct FeedAuthOwnerTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport

    final class Box {
        var access: MaerSyncAccess?
        var identity: MaerSyncIdentity?
    }

    /// One device's keychain in memory: every item with its place, written
    /// through the store's own functions.
    final class Keychain {
        var items: [String: (value: String, synchronizable: Bool)] = [:]
        var feed: Data?
        var code: String?
        /// A resting item reads back otherwise than it was written.
        var restReadsBackWrong = false
        /// Items that cannot be read (the device locked since it started).
        var unreadable: Set<String> = []
        let defaults: UserDefaults
        init(defaults: UserDefaults, feed: Data?, code: String?) {
            self.defaults = defaults; self.feed = feed; self.code = code
        }

        func save(_ account: String, _ value: String, _ synchronizable: Bool) -> Bool {
            items[account] = (value, synchronizable)
            return true
        }
        func load(_ account: String) -> String? {
            guard let value = items[account]?.value else { return nil }
            return restReadsBackWrong && account.hasPrefix("feedAuthRest.") ? value + "x" : value
        }

        func read(_ account: String) -> KeychainRead {
            if unreadable.contains(account) { return .unreadable }
            return load(account).map(KeychainRead.value) ?? .missing
        }

        /// The person's own sign-in for a feed, as `PodcastFeedAuth.set` writes it.
        func signIn(_ feedKey: String, user: String, at: Double) {
            _ = save("feedAuth.\(feedKey)", "\(user)\ngeheim-\(user)", PodcastFeedAuth.travelsOverApple())
            var stamps = (defaults.dictionary(forKey: PodcastFeedAuth.stampsKey) as? [String: Double]) ?? [:]
            stamps[feedKey] = at
            defaults.set(stamps, forKey: PodcastFeedAuth.stampsKey)
        }

        var live: [String: FeedAuthBlock.Entry] {
            var out: [String: FeedAuthBlock.Entry] = [:]
            for (account, item) in items where account.hasPrefix("feedAuth.") {
                let feedKey = String(account.dropFirst("feedAuth.".count))
                let sep = item.value.firstIndex(of: "\n")!
                out[feedKey] = FeedAuthBlock.Entry(
                    credentials: .init(user: String(item.value[..<sep]), password: String(item.value[item.value.index(after: sep)...])),
                    at: PodcastFeedAuth.moment(feedKey: feedKey, defaults: defaults) ?? 0)
            }
            return out
        }

        var keys: FeedAuthSync.Keys {
            FeedAuthSync.Keys(
                code: { self.code }, forgetCode: {}, feed: { _ in self.feed }, mine: { self.live },
                apply: { merged, mine in
                    PodcastFeedAuth.apply(merged, mine: mine, defaults: self.defaults,
                                          writing: { self.save("feedAuth.\($0)", "\($1)\n\($2)", PodcastFeedAuth.travelsOverApple()) })
                },
                rest: { PodcastFeedAuth.rest($1, for: $0, saving: self.save, loading: self.load) },
                rested: { PodcastFeedAuth.rested($1, of: $0, reading: self.read) },
                replace: {
                    PodcastFeedAuth.replaceForNewOwner(with: $0, leaving: $1, defaults: self.defaults,
                                                       saving: self.save, loading: self.load,
                                                       deleting: { self.items[$0] = nil })
                },
                clearRest: { PodcastFeedAuth.clearRest(of: $0, feedKeys: $1, deleting: { self.items[$0] = nil }) })
        }
    }

    static let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
    static let identityA = MaerSyncIdentity(service: "fp-service", owner: "anna")
    static let identityB = MaerSyncIdentity(service: "fp-service", owner: "bert")
    /// A premium address carrying its own token: neither may leave the keychain.
    static let premiumURL = "https://premium.example/feed.xml?token=streng-geheim"
    static var premium: String { PodcastSubscriptions.feedKey(premiumURL) }

    private struct Rig {
        let session: MaerSyncSession
        let transport: FakeTransport
        let box: Box
        let keychain: Keychain
        let runner: FeedAuthSync
        let suite: String
        let folder: URL
        var shelf: RestingShelf { RestingShelf(directory: folder) }
        func cleanup() {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func rig(feed: Data?, code: String?) -> Rig {
        let suite = "feed-owner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let transport = FakeTransport()
        let box = Box()
        box.access = Self.access
        box.identity = Self.identityA
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { box.access }, identity: { box.identity },
                                      deviceId: { "dev-a" }, defaults: defaults)
        let keychain = Keychain(defaults: defaults, feed: feed, code: code)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feed-owner-\(UUID().uuidString)")
        let runner = FeedAuthSync(syncEnabled: { true }, keys: keychain.keys,
                                  identity: { box.identity?.scope }, shelf: RestingShelf(directory: folder))
        return Rig(session: session, transport: transport, box: box, keychain: keychain, runner: runner,
                   suite: suite, folder: folder)
    }

    /// Signs in with another account: one pot per account, swapped here.
    private func switchTo(_ rig: Rig, _ identity: MaerSyncIdentity,
                          pots: inout [String: [String: FakeTransport.Stored]]) async {
        if let current = rig.box.identity { pots[current.scope] = rig.transport.documents }
        rig.transport.documents = pots[identity.scope] ?? [:]
        rig.box.identity = identity
        rig.session.reloadAccess()
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }
        _ = rig.runner.noteLocalChange(by: "witness")
    }

    /// What this device's own block in the pot says, opened with its keys.
    private func ownBlock(_ rig: Rig) -> [String: FeedAuthBlock.Entry]? {
        let key = FakeTransport.key(MaerSyncSession.feedAuthKind, "dev-a")
        guard let body = rig.transport.documents[key]?.body,
              case .plaintext(let plain) = FeedAuthCrypto.open(body, code: rig.keychain.code, feed: rig.keychain.feed),
              case .entries(let entries) = FeedAuthBlock.decode(plain) else { return nil }
        return entries
    }

    /// The case from the decision, once sealed with the feed key and once
    /// with the code alone.
    @Test("A's Zugang ruht im Schluesselbund, B's Block traegt nichts von A, auch mit dem Code versiegelt, der Rueckweg bringt A's Zugang ohne zweites Geraet zurueck",
          arguments: [true, false])
    func theCredentialsRestUnderTheirAccount(sealedWithTheFeedKey: Bool) async throws {
        let rig = rig(feed: sealedWithTheFeedKey ? FeedKeySealingTests.feedK : nil,
                      code: sealedWithTheFeedKey ? nil : FeedKeySealingTests.codeX)
        defer { rig.cleanup() }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        rig.runner.start(session: rig.session, by: "witness")
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }
        #expect(ownBlock(rig)?[Self.premium]?.credentials.user == "anna", "A's block did not go up")

        // Under the build before, this device's block in B's pot carried
        // A's credential already: the first block under B must heal it.
        let leaked = try #require(FeedAuthBlock.encode([Self.premium: FeedKeySealingTests.entry("anna", at: 1000)]))
        let sealed = try #require(sealedWithTheFeedKey
            ? FeedAuthCrypto.seal(leaked, feed: FeedKeySealingTests.feedK)
            : FeedAuthCrypto.seal(leaked, code: FeedKeySealingTests.codeX))
        pots[Self.identityB.scope] = [FakeTransport.key(MaerSyncSession.feedAuthKind, "dev-a"):
                                        .init(body: sealed, format: FeedAuthCrypto.format, version: 1)]

        await switchTo(rig, Self.identityB, pots: &pots)
        #expect(rig.keychain.live[Self.premium] == nil, "A's credential is live under B")
        let ofB = ownBlock(rig)
        #expect(ofB != nil && ofB?[Self.premium] == nil, "B's block carries A's credential (or none went up)")
        let rested = rig.keychain.items.filter { $0.key.hasPrefix("feedAuthRest.") }
        #expect(rested.count == 1, "A's credential does not rest")
        #expect(rested.values.allSatisfy { !$0.synchronizable }, "a resting credential travels off this device")
        #expect(!rested.keys.contains { $0.contains("anna") || $0.contains("premium") }, "the resting name says whose or which")

        // Nothing secret outside the keychain: the shelf and the settings.
        var outside = ""
        for file in FileManager.default.enumerator(atPath: rig.folder.path)?.allObjects as? [String] ?? [] {
            outside += (try? String(contentsOf: rig.folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
        }
        outside += "\(UserDefaults(suiteName: rig.suite)!.dictionaryRepresentation())"
        for secret in ["anna", "geheim", "premium.example", "streng-geheim"] {
            #expect(!outside.contains(secret), "\(secret) stands outside the keychain")
        }

        // B signs in to the same feed with its own credential.
        rig.keychain.signIn(Self.premium, user: "bert", at: 2000)
        _ = rig.runner.noteLocalChange(by: "witness")
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }
        #expect(ownBlock(rig)?[Self.premium]?.credentials.user == "bert")

        await switchTo(rig, Self.identityA, pots: &pots)
        #expect(rig.keychain.live[Self.premium]?.credentials.user == "anna", "A's credential did not come back")
        #expect(rig.keychain.live[Self.premium]?.at == 1000)
        #expect(ownBlock(rig)?[Self.premium]?.credentials.user == "anna", "A's pot holds B's credential")
        let resting = rig.keychain.items.keys.filter { $0.hasPrefix("feedAuthRest.") }
        #expect(resting == ["feedAuthRest.\(Self.identityB.scope).\(Self.premium)"],
                "B's credential does not rest, or A's copy stayed beside the live one: \(resting)")
        withExtendedLifetime(rig.runner) {}
    }

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keinen Zugang von A, A's ruht weiter bei A")
    func aThirdAccountAfterAnOpenReplacement() async throws {
        let rig = rig(feed: FeedKeySealingTests.feedK, code: nil)
        defer { rig.cleanup() }
        let other = PodcastSubscriptions.feedKey("https://other.example/feed.xml")
        let scopeA = Self.identityA.scope
        let scopeB = Self.identityB.scope
        // The replacement of a run before never landed: A's credential is
        // live, and it rests for A as well.
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        #expect(rig.keychain.keys.rest(scopeA, [Self.premium: FeedKeySealingTests.entry("anna", at: 1000)]))
        #expect(rig.keychain.keys.rest(scopeB, [other: FeedKeySealingTests.entry("bert", at: 2000)]))
        try rig.shelf.lay(FeedAuthSync.Resting(moments: [Self.premium: 1000]), of: "feedAuth", owner: scopeA)
        try rig.shelf.lay(FeedAuthSync.Resting(moments: [other: 2000]), of: "feedAuth", owner: scopeB)
        try rig.shelf.setHolding(.init(owner: scopeB, replacing: true, from: scopeA, replacement: "open"), of: "feedAuth")
        rig.box.identity = MaerSyncIdentity(service: "fp-service", owner: "carl")
        rig.runner.start(session: rig.session, by: "witness")
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }
        _ = rig.runner.noteLocalChange(by: "witness")
        #expect(rig.keychain.keys.rested(scopeB, [Self.premium])?.credentials[Self.premium] == nil, "A's credential was laid as B's")
        #expect(try rig.shelf.rest(FeedAuthSync.Resting.self, of: "feedAuth", owner: scopeB)?.moments.keys.sorted() == [other])
        #expect(rig.keychain.keys.rested(scopeA, [Self.premium])?.credentials[Self.premium]?.user == "anna")
        #expect(rig.keychain.live.isEmpty, "C holds a credential of another account")
        withExtendedLifetime(rig.runner) {}
    }

    @Test("ein Wechsel ohne Halter uebergibt die Zugaenge auch vor dem Start des Laeufers: A's ruht unter A, B haelt keinen")
    func aSwitchWithoutAHolder() throws {
        let rig = rig(feed: FeedKeySealingTests.feedK, code: nil)
        defer { rig.cleanup() }
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        rig.box.identity = Self.identityB
        rig.runner.followOwner(previous: Self.identityA.scope)
        #expect(rig.keychain.keys.rested(Self.identityA.scope, [Self.premium])?.credentials[Self.premium]?.user == "anna",
                "A's credential does not rest under A")
        #expect(rig.keychain.live.isEmpty, "B holds A's credential")
        #expect(try rig.shelf.holding(of: "feedAuth")?.owner == Self.identityB.scope)
        withExtendedLifetime(rig.runner) {}
    }

    @Test("ein ruhender Zugang, der fehlt, haelt nicht: Logzeile, der Name faellt vom Regal, die Uebergabe geht weiter; einer, der nicht lesbar ist, haelt")
    func aMissingRestGoesOnAnUnreadableOneHolds() throws {
        let rig = rig(feed: FeedKeySealingTests.feedK, code: nil)
        defer { rig.cleanup() }
        let other = PodcastSubscriptions.feedKey("https://other.example/feed.xml")
        let scopeA = Self.identityA.scope
        let scopeB = Self.identityB.scope
        // B rests with two names, but only one credential is there.
        #expect(rig.keychain.keys.rest(scopeB, [other: FeedKeySealingTests.entry("bert", at: 2000)]))
        try rig.shelf.lay(FeedAuthSync.Resting(moments: [other: 2000, Self.premium: 2100]), of: "feedAuth", owner: scopeB)
        try rig.shelf.setHolding(.init(owner: scopeA), of: "feedAuth")

        // Unreadable: the hand-over holds, nothing replaced.
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        let restOfOther = "feedAuthRest.\(scopeB).\(other)"
        rig.keychain.unreadable = [restOfOther]
        rig.box.identity = Self.identityB
        rig.runner.followOwner(previous: scopeA)
        #expect(rig.keychain.live[Self.premium]?.credentials.user == "anna", "an unreadable rest replaced the live credential")
        #expect(try rig.shelf.holding(of: "feedAuth")?.replacing == true, "the open replacement is not left to finish")
        #expect(rig.keychain.keys.rested(scopeA, [Self.premium])?.credentials[Self.premium]?.user == "anna")

        // Readable again, one name missing: it goes on without it.
        rig.keychain.unreadable = []
        let fresh = FeedAuthSync(syncEnabled: { true }, keys: rig.keychain.keys,
                                 identity: { rig.box.identity?.scope }, shelf: rig.shelf)
        fresh.followOwner(previous: scopeA)
        #expect(rig.keychain.live[other]?.credentials.user == "bert", "the readable rest did not come in")
        #expect(rig.keychain.live[Self.premium] == nil, "A's credential stayed live under B")
        let shelfOfB = try rig.shelf.rest(FeedAuthSync.Resting.self, of: "feedAuth", owner: scopeB)
        #expect(shelfOfB?.moments.keys.sorted() == [other], "the missing name stayed on the shelf")
        #expect(try rig.shelf.holding(of: "feedAuth") == .init(owner: scopeB), "the hand-over held for a missing rest")
        withExtendedLifetime(fresh) {}
    }

    @Test("bleibt beim Ersetzen ein Zugang des Kontos davor stehen, ersetzt nichts und die Runde haelt")
    func aRemovalThatDidNotLandHolds() {
        let suite = "feed-leave-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var items: [String: String] = ["feedAuth.a-key": "anna\ngeheim"]
        let replaced = PodcastFeedAuth.replaceForNewOwner(
            with: [:], leaving: ["a-key"], defaults: defaults,
            saving: { account, value, _ in items[account] = value; return true }, loading: { items[$0] },
            deleting: { _ in })
        #expect(!replaced, "a credential that did not leave counted as left")
        items = ["feedAuth.a-key": "anna\ngeheim"]
        #expect(PodcastFeedAuth.replaceForNewOwner(
            with: [:], leaving: ["a-key"], defaults: defaults,
            saving: { account, value, _ in items[account] = value; return true }, loading: { items[$0] },
            deleting: { items[$0] = nil }))
    }

    @Test("liest ein ruhender Zugang nicht zurueck, wird nichts ersetzt und die Runde haelt")
    func anUnreadRestReplacesNothing() async throws {
        let rig = rig(feed: FeedKeySealingTests.feedK, code: nil)
        defer { rig.cleanup() }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        rig.runner.start(session: rig.session, by: "witness")
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }

        rig.keychain.restReadsBackWrong = true
        await switchTo(rig, Self.identityB, pots: &pots)
        #expect(rig.keychain.live[Self.premium]?.credentials.user == "anna", "a credential left without its rest")
        #expect(ownBlock(rig) == nil, "the held round put a block up in B's pot")
        #expect(try rig.shelf.holding(of: "feedAuth") == .init(owner: Self.identityA.scope))
        withExtendedLifetime(rig.runner) {}
    }

    @Test("entfernt die Person einen Zugang, beruehrt das nur das lebende Konto; der Wechsel zum anderen bringt dessen Zugang")
    func thePersonsRemovalTouchesTheLiveAccountAlone() async throws {
        let rig = rig(feed: FeedKeySealingTests.feedK, code: nil)
        defer { rig.cleanup() }
        var pots: [String: [String: FakeTransport.Stored]] = [:]
        rig.keychain.signIn(Self.premium, user: "anna", at: 1000)
        rig.runner.start(session: rig.session, by: "witness")
        for _ in 0..<3 { await rig.session.refresh(by: "witness") }
        await switchTo(rig, Self.identityB, pots: &pots)
        rig.keychain.signIn(Self.premium, user: "bert", at: 2000)
        _ = rig.runner.noteLocalChange(by: "witness")
        await switchTo(rig, Self.identityA, pots: &pots)
        #expect(rig.keychain.live[Self.premium]?.credentials.user == "anna")

        // Under A the person removes the feed's sign-in.
        var deleted: [String] = []
        PodcastFeedAuth.set(feedKey: Self.premium, user: "", password: "", defaults: rig.keychain.defaults,
                            deleting: { deleted.append($0); rig.keychain.items[$0] = nil })
        #expect(deleted == ["feedAuth.\(Self.premium)"], "the removal reached past the live item: \(deleted)")
        #expect(rig.keychain.live[Self.premium] == nil)

        // B's credential still rests, and the way to B brings it.
        await switchTo(rig, Self.identityB, pots: &pots)
        #expect(rig.keychain.live[Self.premium]?.credentials.user == "bert", "B's hand-over held or lost B's credential")
        withExtendedLifetime(rig.runner) {}
    }

    /// The credential store knows its named removals: the person's own,
    /// and the change of account. A third needs its reason here first.
    nonisolated static let removalStock: [String: String] = [
        "set": "the person cleared the sign-in",
        "clearRest": "the account's own credentials are live again and settled, its resting copies go",
        "remove": "the person disconnected the feed",
        "replaceForNewOwner": "another account owns the device; the credential rests under the name of the account before, read back",
    ]

    @Test("der Zugangs-Speicher kennt genau die benannten Entfernungen, der Kontowechsel ist eine, gerufen an einer Stelle", .needsTheSources)
    func theCredentialStoreHasItsNamedRemovals() throws {
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/PodcastFeedAuth.swift"), encoding: .utf8))
        var found: Set<String> = []
        var current: String?
        for line in store.split(separator: "\n") {
            if let name = line.firstMatch(of: #/static func (\w+)/#)?.1 { current = String(name) }
            if line.contains("KeychainStore.delete("), let current { found.insert(current) }
        }
        #expect(found == Set(Self.removalStock.keys), "a removal outside the named ones: \(found)")
        var callers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !file.path.hasSuffix("/PodcastFeedAuth.swift") {
            if try String(contentsOf: file, encoding: .utf8).contains("PodcastFeedAuth.replaceForNewOwner(") {
                callers.append(file.lastPathComponent)
            }
        }
        #expect(callers == ["FeedAuthSync.swift"], "the change of account removes elsewhere: \(callers)")
    }
}
#endif
