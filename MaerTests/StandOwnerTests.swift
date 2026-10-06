// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stands follow the account (decision of 03.10.2026, a new beginning):
/// the part of the stock that travels with the account rests on the shelf
/// at a switch, the new account sees none of it and gets none of it, a
/// playback that began under the account before writes, sends and claims
/// nothing afterwards, and the way back brings every stand back, in the
/// stock and in its rows. Serialized: the hook of the rows is one global.
@MainActor
@Suite(.serialized)
struct StandOwnerTests {
    /// One pot per account, with every write it got.
    private final class AccountCarrier: StandCarrier {
        var name: String { "accounts" }
        let scope: () -> String?
        var pots: [String: [String: [Double]]] = [:]
        var written: [String: Set<String>] = [:]
        init(scope: @escaping () -> String?) { self.scope = scope }
        func stands() -> [String: [Double]] { pots[scope() ?? "-"] ?? [:] }
        func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
            let key = scope() ?? "-"
            pots[key, default: [:]].merge(upserts) { _, new in new }
            for id in removing { pots[key]?[id] = nil }
            written[key, default: []].formUnion(upserts.keys)
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
        var hasRoomLimit: Bool { false }
        var pullSeconds: Double { 60 }
        var sendCadenceSeconds: Double { 60 }
    }

    private final class RecordingClaims: ClaimCarrier {
        var name: String { "claims" }
        var written: [PlaybackClaim] = []
        func write(_ claim: PlaybackClaim) { written.append(claim) }
        func claims() -> [PlaybackClaim] { written }
        func remove(deviceId: String) {}
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        var heartbeatSeconds: Double { 0 }
    }

    private struct Rig {
        let suite: String
        let defaults: UserDefaults
        let folder: URL
        var shelf: RestingShelf { RestingShelf(directory: folder) }
        func cleanup() {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func rig() -> Rig {
        let suite = "stand-owner-\(UUID().uuidString)"
        return Rig(suite: suite, defaults: UserDefaults(suiteName: suite)!,
                   folder: FileManager.default.temporaryDirectory.appendingPathComponent("stand-owner-\(UUID().uuidString)"))
    }

    /// The runner rounds only with the sync switch on.
    private func withSyncOn(_ body: () async throws -> Void) async rethrows {
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        try await body()
    }

    @Test("A offline gehoert, Wechsel zu B, B bekommt nichts, das weiterlaufende Stueck schreibt nichts, zurueck zu A ist der Stand bei A, auch in den Zeilen")
    func theStandsRestUnderTheirAccount() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let rows = try await StandStore(connection: try SQLiteConnection(path: ":memory:"))
        let mirror = StandMirror(store: rows)
        defer { ListeningStore.onWrite = nil; ListeningStore.onFlushedWrite = nil }
        mirror.start(defaults: defaults)
        try await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            carrier.pots["account-b"] = ["rss:b-1": [120, 1_700_000_000_000, 1800]]
            let runner = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { scope }, shelf: rig.shelf)
            let claims = PlaybackClaimSync(carrier: RecordingClaims(), deviceId: { "this-device" },
                                           ownerEpoch: { ListeningStore.ownerEpoch(in: defaults) })
            runner.reconcile(pushing: false)

            // A listens offline: nothing reaches A's pot yet. A book of the
            // audiobook server stands beside it and belongs to that server.
            let t = 1_700_000_100_000.0
            let epochOfA = ListeningStore.ownerEpoch(in: defaults)
            ListeningStore.record("rss:a-1", position: 600, duration: 3600, atMs: t, epoch: epochOfA, in: defaults)
            ListeningStore.record("abs-book", position: 50, duration: 9000, atMs: t, in: defaults)
            let standOfA = try #require(ListeningStore.backup("rss:a-1", in: defaults))

            scope = "account-b"
            runner.reconcile()
            #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "B sees A's stand")
            #expect(ListeningStore.backup("rss:b-1", in: defaults) != nil, "B's stand did not come in")
            #expect(ListeningStore.backup("abs-book", in: defaults) != nil, "the audiobook server's stand left")

            // The playback that began under A runs on: it writes, sends and
            // claims nothing under B, so the pot has nothing of it to send.
            ListeningStore.record("rss:a-1", position: 700, duration: 3600, atMs: t + 60_000, epoch: epochOfA, in: defaults)
            runner.sendState(changedId: "rss:a-1", deliberate: true, nowMs: t + 60_000)
            runner.reconcile(changedId: "rss:a-1")
            claims.claimIfDue(itemId: "rss:a-1", position: 700, duration: 3600, epoch: epochOfA, forced: true)
            claims.release(itemId: "rss:a-1", position: 700, duration: 3600, epoch: epochOfA)
            #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "the playback of A wrote into B's stock")
            #expect(!(carrier.written["account-b"] ?? []).contains("rss:a-1"), "A's stand went to B")
            #expect(carrier.pots["account-b"]?["rss:a-1"] == nil)
            #expect((claims.current?.itemId ?? "") != "rss:a-1", "A's playback claimed at B")

            // A playback under B writes into B's stock.
            ListeningStore.record("rss:b-2", position: 30, duration: 600, atMs: t + 70_000,
                                  epoch: ListeningStore.ownerEpoch(in: defaults), in: defaults)
            runner.reconcile()
            #expect(carrier.pots["account-b"]?["rss:b-2"] != nil)

            scope = "account-a"
            runner.reconcile()
            #expect(ListeningStore.backup("rss:a-1", in: defaults) == standOfA, "A's stand did not come back as it was")
            #expect(ListeningStore.backup("rss:b-1", in: defaults) == nil && ListeningStore.backup("rss:b-2", in: defaults) == nil,
                    "B's stands stayed with A")
            #expect(carrier.pots["account-a"]?["rss:a-1"] == standOfA, "the stand heard offline did not reach A")
            #expect(carrier.pots["account-a"]?["rss:b-2"] == nil, "B's stand went to A")

            // Row for row.
            await mirror.awaitPendingWrites()
            #expect(try await rows.stand(for: "rss:a-1")?.entry == standOfA)
            #expect(try await rows.stand(for: "rss:b-1") == nil)
            #expect(try await rows.stand(for: "rss:b-2") == nil)
            #expect(try await rows.stand(for: "abs-book") != nil)
            withExtendedLifetime(runner) {}
        }
    }

    @Test("ist der Bestand nicht ganz gelesen, ruht nichts, nichts wird ersetzt und die Runde haelt an")
    func anUnreadStockHoldsTheRound() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let t = 1_700_000_000_000.0
        defaults.set([600.0, t, 3600], forKey: AppStorageKeys.localPosition("rss:a-1"))
        defaults.set(true, forKey: ListeningStore.movedKey)
        struct Unreadable: Error {}
        ListeningStore.installTable(for: defaults) { throw Unreadable() }
        try await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let runner = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { scope }, shelf: rig.shelf)
            runner.reconcile(pushing: false)
            #expect(ListeningStore.readFailed(in: defaults))
            scope = "account-b"
            runner.reconcile()
            #expect(ListeningStore.backup("rss:a-1", in: defaults) != nil, "an unread stock was replaced")
            #expect(carrier.pots["account-b"] == nil, "the held round carried A's stand to B")
            let holding = try rig.shelf.holding(of: "stands")
            #expect(holding == .init(owner: "account-a"))
            withExtendedLifetime(runner) {}
        }
    }

    /// The invariant names two removals: the user's deletion, and the
    /// change of account. A third way to remove a stand needs its reason
    /// here first.
    nonisolated static let removalStock: [String: String] = [
        "clearBackup": "the server took the stand over, its witness stays",
        "move": "an id moved, the stand goes with it",
        "forgetUserDeleted": "the user deleted the item",
        "forgetBackups": "the title no longer exists in its library",
        "replaceForNewOwner": "another account owns the device; the travelling part rests on the shelf, read back",
    ]

    /// The functions of the stock whose bodies set an entry to nil.
    nonisolated static func removingFunctions(in code: String) -> Set<String> {
        var found: Set<String> = []
        var current: String?
        for line in code.split(separator: "\n") {
            if let name = line.firstMatch(of: #/static func (\w+)/#)?.1 { current = String(name) }
            if line.contains(#/stock\.(backups|flushed)\[[^\]]+\] = nil/#), let current { found.insert(current) }
        }
        return found
    }

    @Test("der Bestand kennt genau die benannten Entfernungswege, der Kontowechsel ist einer, gerufen an einer Stelle", .needsTheSources)
    func theStockHasItsNamedRemovals() throws {
        let store = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/ListeningStore.swift"),
                               encoding: .utf8)
        #expect(Self.removingFunctions(in: store) == Set(Self.removalStock.keys),
                "a way to remove a stand outside the stock: \(Self.removingFunctions(in: store))")
        #expect(store.contains("One named exception, the second removal beside the user's deletion"))
        var callers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !file.path.hasSuffix("/ListeningStore.swift") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("ListeningStore.replaceForNewOwner(") { callers.append(file.lastPathComponent) }
        }
        #expect(callers == ["PodcastCloudSync.swift"], "the change of account removes elsewhere: \(callers)")
        // Calibration.
        #expect(Self.removingFunctions(in: "static func a() {\n stock.backups[id] = nil\n}\nstatic func b() {\n stock.backups[id] = x\n}") == ["a"])
    }

    /// The writes and claims of the player that may go without the epoch,
    /// with the reason.
    nonisolated static let epochExceptions: [String: String] = [
        "toggleFinished": "the person marks the item played or unplayed by hand, under the account now",
    ]

    /// Every write and claim of the player: the function it stands in, and
    /// whether the call carries the epoch.
    nonisolated static func playerSites(in code: String) -> [(function: String, carriesEpoch: Bool)] {
        var sites: [(String, Bool)] = []
        for token in ["ListeningStore.record(", "PlaybackClaimSync.shared.claimIfDue(",
                      "PlaybackClaimSync.shared.release(", "PlaybackClaimSync.shared.claim("] {
            var from = code.startIndex
            while let hit = code.range(of: token, range: from..<code.endIndex) {
                // The call ends where its line closes with the parenthesis.
                let call = code[hit.lowerBound...]
                let end = call.range(of: ")\n")?.upperBound ?? call.endIndex
                let function = code[..<hit.lowerBound].matches(of: #/func (\w+)/#).last.map { String($0.1) } ?? "?"
                sites.append((function, code[hit.lowerBound..<end].contains("epoch:")))
                from = hit.upperBound
            }
        }
        return sites
    }

    @Test("jede Aufnahme und jeder Anspruch im Player traegt die Epoche, toggleFinished ist die benannte Ausnahme", .needsTheSources)
    func everyPlayerWriteCarriesTheEpoch() throws {
        let folder = SourceTree.root.appendingPathComponent("Sources/ViewModels")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("PlayerViewModel") && $0.hasSuffix(".swift") }
        var sites: [(function: String, carriesEpoch: Bool)] = []
        for file in files {
            sites += Self.playerSites(in: SyncContractFenceTests.stripped(
                try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)))
        }
        #expect(sites.count == 6, "the player writes or claims at \(sites.count) sites; a new one needs its place here")
        for site in sites where !site.carriesEpoch {
            #expect(Self.epochExceptions[site.function] != nil, "\(site.function) writes or claims without the epoch")
        }
        #expect(Set(sites.filter { !$0.carriesEpoch }.map(\.function)) == Set(Self.epochExceptions.keys),
                "an exception without its site")
        // Calibration.
        let probe = "func a() {\n    ListeningStore.record(id, position: 1,\n        atMs: 2, epoch: e)\n}\nfunc b() {\n    ListeningStore.record(id, position: 1)\n}\n"
        #expect(Self.playerSites(in: probe).map(\.function) == ["a", "b"])
        #expect(Self.playerSites(in: probe).map(\.carriesEpoch) == [true, false])
    }
}
#endif
