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
        defer {
            ListeningStore.onWrite = nil
            ListeningStore.onFlushedWrite = nil
            ListeningStore.installReplacementHook(nil)
        }
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

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keinen Stand von A, A's bleiben bei A")
    func aThirdAccountAfterAnOpenReplacement() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let t = 1_700_000_000_000.0
        // The replacement of a run before never landed: A's stand is live.
        defaults.set([600.0, t, 3600], forKey: AppStorageKeys.localPosition("rss:a-1"))
        let restOfA = ListeningStore.Resting(backups: ["rss:a-1": [600.0, t, 3600]])
        let restOfB = ListeningStore.Resting(backups: ["rss:b-1": [120.0, t, 1800]])
        let shelf = rig.shelf
        try shelf.lay(restOfA, of: "stands", owner: "account-a")
        try shelf.lay(restOfB, of: "stands", owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"), of: "stands")
        try await withSyncOn {
            let carrier = AccountCarrier(scope: { "account-c" })
            let runner = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { "account-c" }, shelf: shelf,
                                          standsMarked: { _ in false })
            #expect(ListeningStore.backup("rss:a-1", in: defaults) != nil, "the precondition: A's stand is live")
            runner.reconcile(pushing: false)
            let restedB = try shelf.rest(ListeningStore.Resting.self, of: "stands", owner: "account-b")
            let restedA = try shelf.rest(ListeningStore.Resting.self, of: "stands", owner: "account-a")
            #expect(restedB == restOfB, "A's stand was laid as B's")
            #expect(restedA == restOfA)
            #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "C sees a stand of another account")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("das Ersetzen der Staende landet in einer Transaktion mit seiner Marke; ein Neustart davor ersetzt nicht noch einmal, was B danach hoerte")
    func theReplacementLandsWithItsMark() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let connection = try SQLiteConnection(path: ":memory:")
        let rows = try await StandStore(connection: connection)
        let mirror = StandMirror(store: rows)
        defer {
            ListeningStore.onWrite = nil
            ListeningStore.onFlushedWrite = nil
            ListeningStore.installReplacementHook(nil)
        }
        mirror.start(defaults: defaults)
        let shelf = rig.shelf
        try await withSyncOn {
            var scope = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let runner = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { scope }, shelf: shelf,
                                          standsMarked: { _ in false })
            runner.reconcile(pushing: false)
            let t = 1_700_000_100_000.0
            ListeningStore.record("rss:a-1", position: 600, duration: 3600, atMs: t,
                                  epoch: ListeningStore.ownerEpoch(in: defaults), in: defaults)
            scope = "account-b"
            runner.reconcile(pushing: false)
            let name = try #require(try shelf.holding(of: "stands")?.replacement)
            await mirror.awaitPendingWrites()
            try await Task.sleep(for: .milliseconds(50))
            let mark = try await connection.query("SELECT replacement FROM owner_mark WHERE family = ?", [.text("stands")])
            #expect(mark.first?["replacement"]?.string == name, "the rows of the replacement landed without its mark")
            #expect(try await rows.stand(for: "rss:a-1") == nil, "the rows still hold A's stand")
            #expect(try shelf.holding(of: "stands") == .init(owner: "account-b"), "the holding did not settle with the mark")

            ListeningStore.record("rss:b-1", position: 30, duration: 600, atMs: t + 60_000,
                                  epoch: ListeningStore.ownerEpoch(in: defaults), in: defaults)
            await mirror.awaitPendingWrites()
            try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: name), of: "stands")
            let restarted = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { scope }, shelf: shelf,
                                             standsMarked: { $0 == name })
            restarted.reconcile(pushing: false)
            #expect(ListeningStore.backup("rss:b-1", in: defaults) != nil, "a landed replacement was done again over B's stand")
            #expect(try shelf.holding(of: "stands") == .init(owner: "account-b"))
            withExtendedLifetime(runner) {}
            withExtendedLifetime(restarted) {}
        }
    }

    @Test("ein Wechsel bei ausgeschaltetem Sync und ohne Halter: A's Staende ruhen unter A, B sieht keinen")
    func aSwitchWithSyncOffAndNoHolder() throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        defaults.set([600.0, 1_700_000_000_000, 3600], forKey: AppStorageKeys.localPosition("rss:a-1"))
        let wasSync = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let wasSync { UserDefaults.standard.set(wasSync, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        let runner = PodcastCloudSync(carrier: AccountCarrier(scope: { "account-b" }), defaults: defaults,
                                      identity: { "account-b" }, shelf: rig.shelf, standsMarked: { _ in false })
        runner.followOwner(previous: "account-a")
        let restOfA = try rig.shelf.rest(ListeningStore.Resting.self, of: "stands", owner: "account-a")
        #expect(restOfA?.backups["rss:a-1"] != nil, "A's stand does not rest under A")
        #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "B sees A's stand")
        withExtendedLifetime(runner) {}
    }

    /// Hands the stock over through the real runner and keeps its carrier:
    /// the app's carrier must never start in a witness.
    private final class HandOverOnly: AccessFollower {
        let runner: PodcastCloudSync
        let note: (String) -> Void
        init(_ runner: PodcastCloudSync, note: @escaping (String) -> Void) { self.runner = runner; self.note = note }
        var followerName: String { "stands" }
        func followOwner(previous: String?) {
            note("handover")
            runner.followOwner(previous: previous)
        }
        func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {}
    }

    /// The register holds what plays before any family hands its stock to
    /// the next account: the stand at the hold carries the epoch of A and
    /// lands in A; written after the hand over it would count for nothing,
    /// and A would come back with the stand from before.
    @Test("ein Kontowechsel haelt das laufende Stueck vor der Uebergabe an: sein Stand beim Anhalten landet bei A, nichts davon bei B")
    func aSwitchHoldsWhatPlaysBeforeTheHandOver() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        try await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let runner = PodcastCloudSync(carrier: carrier, defaults: defaults, identity: { scope }, shelf: rig.shelf)
            runner.reconcile(pushing: false)
            let t = 1_700_000_100_000.0
            let epochOfA = ListeningStore.ownerEpoch(in: defaults)
            ListeningStore.record("rss:a-1", position: 600, duration: 3600, atMs: t, epoch: epochOfA, in: defaults)
            var order: [String] = []
            // The piece played under A runs on to 700 when the switch comes;
            // the hold records it with the epoch it was played in.
            let register = AccessRegister(identity: { scope }, defaults: defaults, onSwitch: {
                order.append("hold")
                ListeningStore.record("rss:a-1", position: 700, duration: 3600, atMs: t + 60_000,
                                      epoch: epochOfA, in: defaults)
            })
            let follower = register.enroll(HandOverOnly(runner) { order.append($0) })

            scope = "account-b"
            register.followAll(by: "sign-in")
            #expect(order == ["hold", "handover"], "order at the switch: \(order)")
            #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "B sees A's stand")
            #expect(carrier.pots["account-b"]?["rss:a-1"] == nil, "A's stand went to B")

            // A second sign-in of B is no switch and holds nothing.
            register.followAll(by: "sign-in")
            #expect(order == ["hold", "handover", "handover"], "a sign-in without a switch held: \(order)")

            scope = "account-a"
            register.followAll(by: "sign-in")
            let back = ListeningStore.backup("rss:a-1", in: defaults)?.first ?? -1
            #expect(back == 700, "A's stand at the hold did not land in A: \(back)")
            withExtendedLifetime(follower) {}
        }
    }

    /// The app's register holds the player, and the player records the
    /// stand under its epoch before it pauses.
    @Test("das Register der App haelt den Player an, der Player nimmt den Stand mit seiner Epoche vor dem Anhalten auf", .needsTheSources)
    func theAppHoldsThePlayerAtASwitch() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let followers = try code("Sources/Networking/AccessFollowers.swift")
        #expect(followers.contains("viewModel?.holdForAccountSwitch()"), "the app's register does not hold the player")
        let player = try code("Sources/ViewModels/PlayerViewModel.swift")
        let hold = try #require(ABSPodcastRefreshTests.body(of: "func holdForAccountSwitch() {", in: player))
        let record = try #require(hold.range(of: "epoch: standEpoch)"), "the hold records without the epoch")
        let pause = try #require(hold.range(of: "pause(caller:"), "the hold does not pause")
        #expect(record.lowerBound < pause.lowerBound, "the hold pauses before it records")
        // A paused piece whose record still waits for the server is held
        // too: the hold asks the rule, the pause of a running piece sets the
        // mark, and only a round that began after it clears the mark.
        #expect(hold.contains("AccountSwitchHold.records(isPlaying: isPlaying, pauseRecordPending: pauseRecordPending)"),
                "the hold does not ask the rule")
        #expect(hold.contains("if isPlaying { pause(caller:"), "the hold pauses what does not play")
        let pausing = try #require(ABSPodcastRefreshTests.body(of: "func pause(caller: String = #function) {", in: player))
        #expect(pausing.contains("if wasPlaying { pauseRecordPending = true }"), "a pause marks no record on its way")
        let sync = try code("Sources/ViewModels/PlayerViewModel+Sync.swift")
        let run = try #require(ABSPodcastRefreshTests.body(of: "func syncProgress(_ origin: SyncOrigin) async {", in: sync))
        #expect(run.contains("if pauseRecordPending { coversPause = true }") && run.contains("if coversPause { pauseRecordPending = false }"),
                "the mark is cleared by a round that did not write the paused stand")
    }

    /// The rule of the hold: a playing piece and a paused one whose record
    /// waits for the server are recorded; a stand recorded long ago is not
    /// stamped anew.
    @Test("beim Kontowechsel wird aufgenommen, wenn ein Stueck spielt oder die Aufnahme seiner Pause noch aussteht, sonst nicht")
    func theHoldRecordsWhatPlaysOrWaits() {
        #expect(AccountSwitchHold.records(isPlaying: true, pauseRecordPending: false))
        #expect(AccountSwitchHold.records(isPlaying: false, pauseRecordPending: true))
        #expect(AccountSwitchHold.records(isPlaying: true, pauseRecordPending: true))
        #expect(!AccountSwitchHold.records(isPlaying: false, pauseRecordPending: false))
    }

    /// The rows of a witness, with the mirror installed on its own defaults.
    private func mirrored(_ defaults: UserDefaults) async throws -> (StandStore, SQLiteConnection, StandMirror) {
        let connection = try SQLiteConnection(path: ":memory:")
        let rows = try await StandStore(connection: connection)
        let mirror = StandMirror(store: rows)
        mirror.start(defaults: defaults)
        return (rows, connection, mirror)
    }

    private func unhook() {
        ListeningStore.onWrite = nil
        ListeningStore.onFlushedWrite = nil
        ListeningStore.installReplacementHook(nil)
    }

    @Test("Schriebe nicht wandernder Kennungen, die eine offene Ersetzung landen, gehen nicht verloren: das Loeschen eines Hoerbuch-Stands und ein Musik-Stand stehen danach richtig in der Tabelle")
    func writesOfIdsThatDoNotTravelSurviveAReplacement() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let (rows, connection, mirror) = try await mirrored(defaults)
        defer { unhook() }
        try await withSyncOn {
            var scope = "account-a"
            let runner = PodcastCloudSync(carrier: AccountCarrier(scope: { scope }), defaults: defaults,
                                          identity: { scope }, shelf: rig.shelf, standsMarked: { _ in false })
            runner.reconcile(pushing: false)
            let t = 1_700_000_100_000.0
            ListeningStore.record("abs-book", position: 50, duration: 9000, atMs: t, in: defaults)
            await mirror.awaitPendingWrites()
            let bookBefore = try await rows.stand(for: "abs-book")
            #expect(bookBefore != nil, "the precondition: the book's stand is in the table")
            let schema = try await connection.query("SELECT sql FROM sqlite_master WHERE name = 'stand_flushed'")
            let createFlushed = try #require(schema.first?["sql"]?.string)

            /// A switch whose own whole write throws, so the replacement
            /// stays open until `write` runs with the rows whole again:
            /// the chain runs at once, a queued write would race the switch.
            @MainActor func switchAndLand(to next: String, by write: () -> Void) async throws {
                _ = try await connection.execute("DROP TABLE stand_flushed")
                scope = next
                runner.reconcile(pushing: false)
                await mirror.awaitPendingWrites()
                let open = try rig.shelf.holding(of: "stands")
                #expect(open?.replacing == true, "the precondition: the replacement is open")
                _ = try await connection.execute(createFlushed)
                write()
                await mirror.awaitPendingWrites()
                let landed = try rig.shelf.holding(of: "stands")
                #expect(landed == .init(owner: next), "the precondition: this write landed the replacement")
            }

            try await switchAndLand(to: "account-b") { ListeningStore.clearBackup("abs-book", in: defaults) }
            let bookAfter = try await rows.stand(for: "abs-book")
            #expect(bookAfter == nil, "the cleared book stand came back")

            try await switchAndLand(to: "account-c") {
                ListeningStore.record("sub:song:1", position: 30, duration: 200, atMs: t + 1_000, in: defaults)
            }
            let song = try await rows.stand(for: "sub:song:1")
            #expect(song != nil, "the music stand was dropped")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("kann der ganze Schrieb nicht landen, Bestand nicht geladen oder ein Wurf, laeuft jeder andere Schrieb trotzdem, und das Ersetzen wird wieder versucht")
    func aHeldWholeWriteDropsNoOtherWrite() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let (rows, connection, mirror) = try await mirrored(defaults)
        defer { unhook() }
        try await withSyncOn {
            var scope = "account-a"
            let runner = PodcastCloudSync(carrier: AccountCarrier(scope: { scope }), defaults: defaults,
                                          identity: { scope }, shelf: rig.shelf, standsMarked: { _ in false })
            runner.reconcile(pushing: false)
            let t = 1_700_000_100_000.0
            await mirror.awaitPendingWrites()
            // The whole write throws: the table it writes into is gone
            // before the switch opens the replacement, whenever it runs.
            let schema = try await connection.query("SELECT sql FROM sqlite_master WHERE name = 'stand_flushed'")
            let createFlushed = try #require(schema.first?["sql"]?.string)
            _ = try await connection.execute("DROP TABLE stand_flushed")
            scope = "account-b"
            runner.reconcile(pushing: false)
            ListeningStore.record("sub:song:1", position: 30, duration: 200, atMs: t, in: defaults)
            await mirror.awaitPendingWrites()
            let afterThrow = try await rows.stand(for: "sub:song:1")
            #expect(afterThrow != nil, "a write was dropped after the whole write threw")
            let heldAfterThrow = try rig.shelf.holding(of: "stands")
            #expect(heldAfterThrow?.replacing == true, "the replacement settled without its rows")

            // The stock not loaded: a write that reaches the rows without
            // asking the stock, so nothing loads it before the whole write.
            _ = try await connection.execute(createFlushed)
            let backups = ListeningStore.positions(in: defaults)
            ListeningStore.installTable(for: defaults) { ListeningStore.Stock(backups: backups, flushed: [:]) }
            mirror.note(itemId: "sub:song:2", entry: [40, t + 1_000, 200], in: ObjectIdentifier(defaults))
            await mirror.awaitPendingWrites()
            let afterUnloaded = try await rows.stand(for: "sub:song:2")
            #expect(afterUnloaded != nil, "a write was dropped while the stock was not loaded")
            let heldAfterUnloaded = try rig.shelf.holding(of: "stands")
            #expect(heldAfterUnloaded?.replacing == true, "the replacement settled without its rows")

            // The next write with the stock loaded lands the replacement.
            ListeningStore.record("sub:song:3", position: 50, duration: 200, atMs: t + 2_000, in: defaults)
            await mirror.awaitPendingWrites()
            let afterLanding = try await rows.stand(for: "sub:song:3")
            #expect(afterLanding != nil, "the write after the landing was dropped")
            let settled = try rig.shelf.holding(of: "stands")
            #expect(settled == .init(owner: "account-b"), "the replacement was not tried again")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("ein Neustart im gehaltenen Fenster: danach steht kein wandernder Stand des Kontos davor unter dem jetzigen; gemessen, was aus dem Schrieb des neuen Kontos aus dem Fenster wird")
    func aRestartInTheHeldWindow() async throws {
        let rig = rig()
        defer { rig.cleanup() }
        let defaults = rig.defaults
        let (rows, connection, mirror) = try await mirrored(defaults)
        defer { unhook() }
        try await withSyncOn {
            var scope = "account-a"
            let runner = PodcastCloudSync(carrier: AccountCarrier(scope: { scope }), defaults: defaults,
                                          identity: { scope }, shelf: rig.shelf, standsMarked: { _ in false })
            runner.reconcile(pushing: false)
            let t = 1_700_000_100_000.0
            ListeningStore.record("rss:a-1", position: 600, duration: 3600, atMs: t, in: defaults)
            await mirror.awaitPendingWrites()
            // The whole write throws, so the window stays open; in it B
            // writes a travelling stand, which goes into the rows beside A's.
            let schema = try await connection.query("SELECT sql FROM sqlite_master WHERE name = 'stand_flushed'")
            let createFlushed = try #require(schema.first?["sql"]?.string)
            _ = try await connection.execute("DROP TABLE stand_flushed")
            scope = "account-b"
            runner.reconcile(pushing: false)
            ListeningStore.record("rss:b-1", position: 30, duration: 600, atMs: t + 60_000, in: defaults)
            await mirror.awaitPendingWrites()
            let aInTheWindow = try await rows.stand(for: "rss:a-1")
            let bInTheWindow = try await rows.stand(for: "rss:b-1")
            #expect(aInTheWindow != nil && bInTheWindow != nil, "the precondition: both stand in the rows, unmarked")

            // The process ends here. The next start finds the rows whole,
            // and they are the stock; the open replacement of the mirror is gone.
            _ = try await connection.execute(createFlushed)
            let table = ListeningStore.Stock(backups: try await rows.all().mapValues(\.entry),
                                             flushed: try await rows.allFlushed())
            ListeningStore.markMoved(for: ObjectIdentifier(defaults))
            ListeningStore.installTable(for: defaults) { table }
            #expect(ListeningStore.backup("rss:a-1", in: defaults) != nil, "the precondition: A's stand is in the stock after the start")
            let started = StandMirror(store: rows)
            started.start(defaults: defaults)
            let restarted = PodcastCloudSync(carrier: AccountCarrier(scope: { scope }), defaults: defaults,
                                             identity: { scope }, shelf: rig.shelf, standsMarked: { _ in false })
            restarted.reconcile(pushing: false)
            await started.awaitPendingWrites()

            #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "A's stand stands under B after the restart")
            let aAfter = try await rows.stand(for: "rss:a-1")
            #expect(aAfter == nil, "A's stand stays in B's rows after the restart")
            let settled = try rig.shelf.holding(of: "stands")
            #expect(settled == .init(owner: "account-b"), "the replacement after the restart did not land")
            // An open state, held until it is decided, not a property: B's
            // write from the window is not in B's rest, so the replacement
            // after the restart takes it with A's.
            #expect(ListeningStore.backup("rss:b-1", in: defaults) == nil,
                    "the open state moved: B's write from the window survives now, the decision is due")
            let bAfter = try await rows.stand(for: "rss:b-1")
            #expect(bAfter == nil, "the open state moved: B's row from the window survives now, the decision is due")
            withExtendedLifetime(runner) {}
            withExtendedLifetime(restarted) {}
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
        // Seven: the hold at a change of account records with the epoch too.
        #expect(sites.count == 7, "the player writes or claims at \(sites.count) sites; a new one needs its place here")
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
