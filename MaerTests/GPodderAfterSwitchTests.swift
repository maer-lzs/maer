// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// gpodder after a change of account: its sign-in belongs to the device, so
/// it rests while another account holds the subscriptions. Going on with
/// this account leaves the feeds only on the gpodder server where they are,
/// never in this account and never removed; disconnecting signs the device
/// out and changes nothing on the server. No way takes a feed of the
/// account before into the new one or removes it.
@MainActor
@Suite(.serialized)
struct GPodderAfterSwitchTests {
    private func shelf() -> (RestingShelf, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpodder-switch-\(UUID().uuidString)")
        return (RestingShelf(directory: folder), folder)
    }

    @Test("the rest: no holder runs, another holder rests, an unreadable holder rests too, with a sentence")
    func theRest() throws {
        let (shelf, folder) = shelf()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs)
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs, "gpodder takes the first holder")
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .restsAfterSwitch)
        #expect(GPodderRest.runs.sentence == nil)
        #expect(GPodderRest.restsAfterSwitch.sentence != nil && GPodderRest.ownerUnreadable.sentence != nil)
        let holding = folder.appendingPathComponent(PodcastSubscriptions.shelfFamily, isDirectory: true)
            .appendingPathComponent("holding.json")
        try Data("not json".utf8).write(to: holding)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .ownerUnreadable)
    }

    @Test("ten ticks over an unreadable shelf give one line, a shelf read again and unreadable again gives the next")
    func anUnreadableShelfWritesOneLinePerState() throws {
        let (shelf, folder) = shelf()
        defer { try? FileManager.default.removeItem(at: folder) }
        GPodderSync.testResetRestLog()
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs)
        let holding = folder.appendingPathComponent(PodcastSubscriptions.shelfFamily, isDirectory: true)
            .appendingPathComponent("holding.json")
        try Data("not json".utf8).write(to: holding)
        for _ in 0..<10 {
            #expect(GPodderSync.followsTheSubscriptions(on: shelf, quietly: true) == false)
        }
        #expect(GPodderSync.restLog.lines == 1, "one line for ten ticks")
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs)
        try Data("not json".utf8).write(to: holding)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .ownerUnreadable)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .ownerUnreadable)
        #expect(GPodderSync.restLog.lines == 2, "the shelf read again, so its next failure is a new state")
    }

    @Test("the rule of the line: only an unreadable shelf after a different answer")
    func theRestLogRule() {
        var log = GPodderRestLog()
        let answers: [GPodderRest] = [.runs, .restsAfterSwitch, .ownerUnreadable, .ownerUnreadable, .restsAfterSwitch, .ownerUnreadable]
        let due = answers.map { log.due($0) }
        #expect(due == [false, false, true, false, false, true])
        #expect(log.lines == 2)
    }

    @Test("gpodder sees the left-behind feeds in neither direction until this device subscribes to one itself")
    func theLeftFeedsAreUnseen() {
        let server = ["a": "https://a.example/feed", "s": "https://s.example/feed"]
        let left = GPodderVisibleSubscriptions.leftOnServer(server: Set(server.keys), local: ["s", "b"])
        #expect(left == ["a"])
        #expect(GPodderVisibleSubscriptions.visibleServerURLs(server, premiumOptIn: true, leftOnServer: left).keys.sorted() == ["s"])
        #expect(GPodderVisibleSubscriptions.withoutLeftOnServer(server, left).keys.sorted() == ["s"])
        #expect(GPodderVisibleSubscriptions.stillLeft(left, local: ["s", "a"]).isEmpty,
                "a left feed this device subscribes itself stays hidden and would read as removed")
    }

    @Test("the conflict sheet sees the server like the round: without left-behind feeds and, without opt-in, without token feeds")
    func theConflictSheetSeesTheServerLikeTheRound() {
        let token = "https://premium.example/feed?auth=SECRETTOKEN1234567890"
        let plain = "https://plain.example/feed", left = "https://left.example/feed"
        let leftNorm = PodcastIdentity.normalizeFeedURL(left)
        let tokenNorm = PodcastIdentity.normalizeFeedURL(token)
        let off = GPodderSync.conflictSnapshot(serverURLs: [token, plain, left], localRaw: [:],
                                               premiumOptIn: false, leftOnServer: [leftNorm])
        let seenOff = off.serverNorms
        #expect(seenOff == [PodcastIdentity.normalizeFeedURL(plain)], "without the opt-in: \(seenOff)")
        let on = GPodderSync.conflictSnapshot(serverURLs: [token, plain, left], localRaw: [:],
                                              premiumOptIn: true, leftOnServer: [leftNorm])
        let seenOn = on.serverNorms
        #expect(seenOn.contains(tokenNorm) && !seenOn.contains(leftNorm), "with the opt-in: \(seenOn)")
    }

    /// Going on with this account writes the holder before the keys: when
    /// the holder cannot be written, nothing of the account before changes,
    /// so its return goes on with its own state.
    @Test("Going on when the holder cannot be written: no key changes")
    func aFailedHolderChangesNoKey() throws {
        let kept = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let (shelf, folder) = shelf()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        AppStorageKeys.set(["kept"], for: AppStorageKeys.gpodderLastSyncedFeeds)
        AppStorageKeys.set(["keptLeft"], for: AppStorageKeys.gpodderLeftOnServer)
        AppStorageKeys.set(["pending"], for: AppStorageKeys.gpodderPendingRemoveLocal)
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let error = GPodderSync.shared.continueWithThisAccount(serverURLs: ["https://only-on-server.example/feed"], shelf: shelf)
        #expect(error != nil, "the precondition: the holder could not be written")
        let synced = AppStorageKeys.stringArray(AppStorageKeys.gpodderLastSyncedFeeds)
        let leftList = AppStorageKeys.stringArray(AppStorageKeys.gpodderLeftOnServer)
        let pending = AppStorageKeys.stringArray(AppStorageKeys.gpodderPendingRemoveLocal)
        #expect(synced == ["kept"], "the state of the account before changed: \(String(describing: synced))")
        #expect(leftList == ["keptLeft"], "the left feeds changed: \(String(describing: leftList))")
        #expect(pending == ["pending"], "the pending removals went: \(String(describing: pending))")
    }

    private static let keys = [AppStorageKeys.gpodderLastSyncedFeeds, AppStorageKeys.gpodderPendingRemoveLocal,
                               AppStorageKeys.gpodderPendingRemoveServer, AppStorageKeys.gpodderUserRemovedFeeds,
                               AppStorageKeys.gpodderLeftOnServer]

    private func show(_ feedURL: String) -> PodcastShow {
        PodcastShow(id: "rss:\(PodcastIdentity.feedKey(feedURL))", title: "Show", author: "Host",
                    artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: "\(feedURL)#1", title: "Ep", audioURL: "\(feedURL).mp3",
                                              pubDate: 1_700_000_000_000, duration: 1800,
                                              description: nil, imageURL: nil, chaptersURL: nil)])
    }

    /// The two owners: A's feed stands on the gpodder server, B holds the
    /// subscriptions on this device. Every way after the switch.
    @Test("after the switch: A's feed stays on the gpodder server and never appears for B, by no way; B's feed goes to the server")
    func noWayTakesTheFeedOfTheAccountBefore() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let run = UUID().uuidString.prefix(8)
        let aFeed = "https://switch-a.example/\(run)/feed.xml"
        let bFeed = "https://switch-b.example/\(run)/feed.xml"
        let shared = "https://switch-s.example/\(run)/feed.xml"
        let aNorm = PodcastIdentity.normalizeFeedURL(aFeed)
        let kept = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let shows = subs.serverShows, read = subs.serverShowsRead, reader = subs.readServerShows
        let (shelf, folder) = shelf()
        defer {
            subs.serverShows = shows
            subs.serverShowsRead = read
            subs.readServerShows = reader
            subs._testFeedFetcher = nil
            for show in subs.shows where [aFeed, bFeed, shared].contains(show.feedURL) {
                subs.unsubscribe(id: show.id, notesCloud: false)
            }
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        subs.serverShowsRead = { true }
        subs.serverShows = { [] }
        subs.readServerShows = {}
        subs._testFeedFetcher = { url in .show(self.show(url.absoluteString)) }
        for feed in [bFeed, shared] {
            _ = await subs.subscribeUnlessOnServer(urlString: feed, notesCloud: false, isSingleUserAct: false)
        }
        #expect(subs.shows.contains { $0.feedURL == bFeed } && subs.shows.contains { $0.feedURL == shared },
                "the precondition: B's subscriptions stand here")
        try shelf.setHolding(.init(owner: "account-a"), of: GPodderSync.shelfFamily)
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        let gpodder = SubscriptionFamilyServerTests.FakeGPodder([aFeed, shared])
        let sync = GPodderSync.shared
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .restsAfterSwitch, "the precondition: gpodder rests")

        // The conflict path in the rest: nothing taken, nothing removed.
        let raw = [aNorm: aFeed]
        let snapshot = GPodderSync.ConflictSnapshot(localNorms: [], serverNorms: [aNorm], localRaw: [:], serverRaw: raw)
        let take = GPodderConflictResolution.resolve(local: [], server: [aNorm], choices: [:])
        #expect(take.subscribeLocally == [aNorm], "the precondition: the resolution would take A's feed")
        var uploads = 0
        let said = await sync.applyConflictResolution(take, snapshot: snapshot,
                                                      rest: GPodderSync.rest(on: shelf, quietly: true)) { _, _ in uploads += 1 }
        #expect(said == GPodderRest.restsAfterSwitch.sentence, "the conflict path in the rest did not say so")
        #expect(uploads == 0)
        #expect(!subs.shows.contains { $0.feedURL == aFeed }, "the conflict path took A's feed into B's subscriptions")

        // Going on with this account: A's feed is left, gpodder follows B.
        #expect(sync.continueWithThisAccount(serverURLs: Array(gpodder.server), shelf: shelf) == nil)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs, "gpodder does not follow B after going on")
        #expect(Set(AppStorageKeys.stringArray(AppStorageKeys.gpodderLeftOnServer) ?? []) == [aNorm])

        // Two rounds: B's feed goes up, A's stays on the server, never here.
        _ = try await sync.syncSubscriptions(gpodder)
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(gpodder.server.contains(bFeed), "B's feed did not reach the gpodder server")
        #expect(gpodder.server.contains(aFeed), "A's feed was removed from the gpodder server")
        #expect(!gpodder.uploads.contains { $0.remove.contains(aFeed) })
        #expect(!subs.shows.contains { $0.feedURL == aFeed }, "A's feed came into B's subscriptions")

        // B subscribes that feed himself later: it is shared, not removed.
        _ = await subs.subscribeUnlessOnServer(urlString: aFeed, notesCloud: false, isSingleUserAct: false)
        _ = try await sync.syncSubscriptions(gpodder)
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(subs.shows.contains { $0.feedURL == aFeed }, "B's own subscription of the left feed was removed")
        #expect(gpodder.server.contains(aFeed))
        #expect(AppStorageKeys.stringArray(AppStorageKeys.gpodderLeftOnServer)?.contains(aNorm) != true)
    }

    @Test("disconnecting gpodder signs this device out, nothing changes on the server, and gpodder no longer rests afterwards")
    func disconnectSignsTheDeviceOut() throws {
        let stateKeys = [AppStorageKeys.gpodderServerURL, AppStorageKeys.gpodderUsername,
                         AppStorageKeys.gpodderDeviceRegisteredFor] + Self.keys
        let kept = stateKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let password = AppStorageKeys.gpodderPasswordValue
        let (shelf, folder) = shelf()
        defer {
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
            AppStorageKeys.setGpodderPassword(password)
            try? FileManager.default.removeItem(at: folder)
        }
        AppStorageKeys.gpodderServerURLValue = "https://gpodder.example"
        AppStorageKeys.gpodderUsernameValue = "someone"
        AppStorageKeys.set(["x"], for: AppStorageKeys.gpodderLastSyncedFeeds)
        AppStorageKeys.set(["y"], for: AppStorageKeys.gpodderLeftOnServer)
        try shelf.setHolding(.init(owner: "account-a"), of: GPodderSync.shelfFamily)
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .restsAfterSwitch, "the precondition: gpodder rests")
        GPodderSync.shared.disconnect(shelf: shelf)
        #expect(AppStorageKeys.gpodderServerURLValue.isEmpty && AppStorageKeys.gpodderUsernameValue.isEmpty)
        #expect(AppStorageKeys.gpodderPasswordValue.isEmpty)
        #expect(AppStorageKeys.stringArray(AppStorageKeys.gpodderLastSyncedFeeds) == nil)
        #expect(AppStorageKeys.stringArray(AppStorageKeys.gpodderLeftOnServer) == nil)
        #expect(GPodderSync.rest(on: shelf, quietly: true) == .runs)
    }
}
#endif
