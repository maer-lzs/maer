// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// gpodder conflict resolution: per-feed keep-local / take-server / union
/// default converge to the expected state + apply actions.
struct GPodderConflictResolutionTests {
    let local: Set<String> = ["a", "b"]     // local-only: a ; shared: b
    let server: Set<String> = ["b", "c"]    // server-only: c ; shared: b

    @Test("conflicting feeds: only here, then only on the server, each sorted")
    func conflicts() {
        let both = GPodderConflictResolution.conflictingFeeds(local: local, server: server)
        #expect(both.localOnly == ["a"] && both.serverOnly == ["c"])
        // The page shows two sections, not one merged list: "c" here and "a"
        // there stay apart, whatever their order.
        let apart = GPodderConflictResolution.conflictingFeeds(local: ["c", "d"], server: ["a"])
        #expect(apart.localOnly == ["c", "d"] && apart.serverOnly == ["a"])
    }

    /// The page shows the feeds of `conflictingFeeds`, and the apply decides
    /// the same feeds: one root for both sets, so a feed can never be
    /// decided that the page did not show, or shown and then not decided.
    @Test("die Seite und das Anwenden nehmen die Konflikte aus einer Wurzel", .needsTheSources)
    func oneRootForTheConflicts() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderConflictResolution.swift"),
            encoding: .utf8))
        let resolve = try #require(code.range(of: "static func resolve("), "the precondition: resolve was read")
        let body = code[resolve.upperBound...]
        #expect(body.contains("conflictingFeeds(local: local, server: server)"), "the apply computes its own conflicts")
        #expect(!code.contains("symmetricDifference"), "a second form of the conflict set is back")
        let view = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/GPodderConflictResolutionView.swift"),
            encoding: .utf8))
        #expect(view.contains("GPodderConflictResolution.conflictingFeeds("), "the page computes its own conflicts")
    }

    /// The synced set is built from what landed: a feed taken from the
    /// server counts only once it was subscribed here, as in the ordinary
    /// round.
    @Test("der abgeglichene Satz nimmt vom Server nur, was hier abonniert wurde")
    func theSyncedSetTakesOnlyWhatWasSubscribed() {
        let actions = GPodderConflictResolution.resolve(local: local, server: server, choices: [:])
        #expect(actions.subscribeLocally == ["c"], "the precondition: c is taken from the server")
        #expect(GPodderConflictResolution.synced(actions, subscribed: []) == ["a", "b"])
        #expect(GPodderConflictResolution.synced(actions, subscribed: ["c"]) == actions.converged)
        #expect(GPodderConflictResolution.synced(actions, subscribed: ["z"]) == ["a", "b"], "a feed nobody took counted")
    }

    /// The three ways a feed taken from the server does not land here (set
    /// out, held on Audiobookshelf, a failed fetch), each through the sheet
    /// and then three ordinary rounds: the server keeps every feed and gets
    /// no removal from this device. A set out one is said.
    @Test("nach dem Aufloesen bekommt der gpodder-Server keine Entfernung fuer ein Abo, das hier nicht ankam")
    @MainActor
    func aFeedThatDidNotLandHereIsNotRemovedFromTheServer() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let run = UUID().uuidString.prefix(8)
        let held = "https://resolve-held.example/\(run)/feed.xml"
        let failed = "https://resolve-failed.example/\(run)/feed.xml"
        let setOut = "https://resolve-setout.example/\(run)/feed.xml"
        let keys = [AppStorageKeys.gpodderLastSyncedFeeds, AppStorageKeys.gpodderPendingRemoveLocal,
                    AppStorageKeys.gpodderPendingRemoveServer, AppStorageKeys.gpodderUserRemovedFeeds]
        let kept = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let shows = subs.serverShows, read = subs.serverShowsRead, reader = subs.readServerShows
        let notice = subs.serverUnreadNotice
        defer {
            subs.serverShows = shows
            subs.serverShowsRead = read
            subs.readServerShows = reader
            subs._testFeedFetcher = nil
            subs.serverUnreadNotice = notice
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
        }
        func pass(_ feeds: [String], serverRead: Bool) async throws {
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
            subs.serverShowsRead = { serverRead }
            subs.serverShows = { [ServerHeldImportTests.serverShow(feedURL: held, title: "Server Show")] }
            subs.readServerShows = {}
            subs._testFeedFetcher = { _ in .failed(.timeout) }
            let raw = Dictionary(uniqueKeysWithValues: feeds.map { (PodcastSubscriptions.normalizeFeedURL($0), $0) })
            let snapshot = GPodderSync.ConflictSnapshot(localNorms: [], serverNorms: Set(raw.keys), localRaw: [:], serverRaw: raw)
            let actions = GPodderConflictResolution.resolve(local: [], server: Set(raw.keys), choices: [:])
            #expect(actions.subscribeLocally == Set(raw.keys), "the precondition: every feed is taken from the server")
            let error = await GPodderSync.shared.applyConflictResolution(actions, snapshot: snapshot) { _, _ in }
            #expect(error == nil)
            let synced = Set(UserDefaults.standard.stringArray(forKey: AppStorageKeys.gpodderLastSyncedFeeds) ?? [])
            #expect(synced.isDisjoint(with: raw.keys), "a feed that did not land here counts as synced: \(synced)")
            // Three ordinary rounds: a removal toward the server waits for a
            // second confirming round, so only the third could send one.
            let gpodder = SubscriptionFamilyServerTests.FakeGPodder(Set(feeds))
            for _ in 0..<3 { _ = try await GPodderSync.shared.syncSubscriptions(gpodder) }
            // The shared store may push its own shows up; none of these leaves.
            #expect(Set(feeds).isSubset(of: gpodder.server), "the server lost a feed: \(gpodder.server)")
            #expect(gpodder.uploads.allSatisfy { $0.remove.isEmpty }, "this device sent the server a removal: \(gpodder.uploads)")
            #expect(!subs.shows.contains { feeds.contains($0.feedURL) }, "the precondition: none of them landed here")
        }
        // Held on Audiobookshelf and a failed fetch: the server was read.
        try await pass([held, failed], serverRead: true)
        // Set out: Audiobookshelf could not be read, and the person hears it.
        subs.serverUnreadNotice = false
        try await pass([setOut], serverRead: false)
        #expect(subs.serverUnreadNotice, "a set out subscription was silent")
    }

    @Test("union default (no choices) keeps everything — nothing lost")
    func unionDefault() {
        let a = GPodderConflictResolution.resolve(local: local, server: server, choices: [:])
        #expect(a.converged == ["a", "b", "c"])
        #expect(a.addToServer == ["a"])          // local-only a → push to server
        #expect(a.subscribeLocally == ["c"])     // server-only c → subscribe locally
        #expect(a.unsubscribeLocally.isEmpty)
        #expect(a.removeFromServer.isEmpty)
    }

    @Test("keep-local for all: local wins")
    func keepLocalAll() {
        let a = GPodderConflictResolution.resolve(
            local: local, server: server, choices: ["a": .keepLocal, "c": .keepLocal])
        #expect(a.converged == ["a", "b"])       // c (server-only) dropped
        #expect(a.addToServer == ["a"])          // push a to server
        #expect(a.removeFromServer == ["c"])     // drop c from server
        #expect(a.subscribeLocally.isEmpty)
        #expect(a.unsubscribeLocally.isEmpty)
    }

    @Test("take-server for all: server wins")
    func takeServerAll() {
        let a = GPodderConflictResolution.resolve(
            local: local, server: server, choices: ["a": .takeServer, "c": .takeServer])
        #expect(a.converged == ["b", "c"])       // a (local-only) dropped
        #expect(a.unsubscribeLocally == ["a"])   // drop a locally
        #expect(a.subscribeLocally == ["c"])     // subscribe c locally
        #expect(a.addToServer.isEmpty)
        #expect(a.removeFromServer.isEmpty)
    }

    @Test("mixed per-feed choices")
    func mixed() {
        // Keep local a (push), drop server c (remove from server).
        let a = GPodderConflictResolution.resolve(
            local: local, server: server, choices: ["a": .keepLocal, "c": .keepLocal])
        #expect(a.converged == ["a", "b"])
        // No conflict feeds beyond a/c → shared b always stays.
        #expect(a.converged.contains("b"))
    }
}
#endif
