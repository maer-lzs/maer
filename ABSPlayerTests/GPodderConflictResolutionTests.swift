// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// gpodder conflict resolution: per-feed keep-local / take-server / union
/// default converge to the expected state + apply actions.
struct GPodderConflictResolutionTests {
    let local: Set<String> = ["a", "b"]     // local-only: a ; shared: b
    let server: Set<String> = ["b", "c"]    // server-only: c ; shared: b

    @Test("conflicting feeds = symmetric difference, sorted")
    func conflicts() {
        #expect(GPodderConflictResolution.conflictingFeeds(local: local, server: server) == ["a", "c"])
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
