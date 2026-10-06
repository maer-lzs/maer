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
                rested: { PodcastFeedAuth.rested($1, of: $0, loading: self.load) },
                replace: {
                    PodcastFeedAuth.replaceForNewOwner(with: $0, leaving: $1, defaults: self.defaults,
                                                       saving: self.save, loading: self.load,
                                                       deleting: { self.items[$0] = nil })
                })
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
        #expect(rested.values.allSatisfy { $0.synchronizable == PodcastFeedAuth.travelsOverApple() },
                "the resting item sits elsewhere than the live one")
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
        #expect(rig.keychain.items.keys.filter { $0.hasPrefix("feedAuthRest.") }.count == 2, "B's credential does not rest")
        withExtendedLifetime(rig.runner) {}
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

    /// The credential store knows its named removals: the person's own,
    /// and the change of account. A third needs its reason here first.
    nonisolated static let removalStock: [String: String] = [
        "set": "the person cleared the sign-in",
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
