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
