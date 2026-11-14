// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A write that took the account's epoch before its work writes nothing into
/// the stock of the account after a change, and a writer that decides from
/// the entry decides from the entry as it stands when it writes.
struct EpochUnderLockTests {
    private func suite() -> (UserDefaults, String) {
        let name = "epoch-under-lock-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("store and merge with the epoch from before an account change write nothing into the stock afterwards, with the new one they do")
    func aWriteWithTheEpochBeforeASwitchWritesNothing() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let before = ListeningStore.ownerEpoch(in: defaults)
        ListeningStore.replaceForNewOwner(with: nil, where: { $0.hasPrefix("rss:") }, in: defaults)
        let now = ListeningStore.ownerEpoch(in: defaults)
        #expect(now != before, "the precondition: the switch moved the epoch")

        ListeningStore.store("rss:a-1", entry: [600, 1_700_000_000_000, 3600], epoch: before, in: defaults)
        let merged = ListeningStore.merge("rss:a-2", epoch: before, in: defaults) { _ in [900, 1_700_000_000_000, 3600] }
        #expect(ListeningStore.backup("rss:a-1", in: defaults) == nil, "a store of the account before landed after the switch")
        #expect(merged == nil && ListeningStore.backup("rss:a-2", in: defaults) == nil,
                "a merge of the account before landed after the switch")

        ListeningStore.store("rss:b-1", entry: [30, 1_700_000_100_000, 600], epoch: now, in: defaults)
        #expect(ListeningStore.backup("rss:b-1", in: defaults) == [30, 1_700_000_100_000, 600], "a store of the account now was dropped")
    }

    @Test("the adoption from gpodder decides on the entry as it is now: a newer write of the player between reading and writing stays")
    func theMergeDecidesFromTheEntryAsItStands() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let epoch = ListeningStore.ownerEpoch(in: defaults)
        // What the round read before, and the player's newer write after it.
        ListeningStore.record("rss:x", position: 100, duration: 3600, atMs: 1_000, in: defaults)
        let read = ListeningStore.backup("rss:x", in: defaults)
        ListeningStore.record("rss:x", position: 500, duration: 3600, atMs: 5_000, in: defaults)
        #expect(GPodderMergePath.of(local: read, serverTsMs: 3_000, serverTotal: 3600) == .adopt,
                "the precondition: against the entry it read, the round would adopt the server")

        ListeningStore.merge("rss:x", epoch: epoch, in: defaults) { local in
            switch GPodderMergePath.of(local: local, serverTsMs: 3_000, serverTotal: 3600) {
            case .adopt: return ProgressMark.advancing(local, position: 300, duration: 3600, nowMs: 3_000)
            case .supplement(let healed): return healed
            case nil: return nil
            }
        }
        #expect(ListeningStore.backup("rss:x", in: defaults)?.first == 500, "the server's older state overwrote the player's newer one")
    }

    @Test("the path of the adoption: newer wins, equally old adds only the duration, nothing else")
    func thePathOfAPulledPlay() {
        #expect(GPodderMergePath.of(local: nil, serverTsMs: 10, serverTotal: 0) == .adopt)
        #expect(GPodderMergePath.of(local: [5, 10], serverTsMs: 20, serverTotal: 0) == .adopt)
        #expect(GPodderMergePath.of(local: [5, 20, 300], serverTsMs: 20, serverTotal: 300) == nil)
        if case .supplement(let healed) = GPodderMergePath.of(local: [5, 20], serverTsMs: 20, serverTotal: 300) {
            #expect(healed.first == 5 && healed.count >= 3, "the supplement keeps the position and adds the duration")
        } else {
            Issue.record("an entry without its duration is supplemented")
        }
    }

    /// The race these close needs two threads; a witness on one cannot make
    /// it happen. So the shape is fenced: the epoch moves in the lock of the
    /// swap, every write asks it in the lock of its write, and the gpodder
    /// round goes through `merge` with the epoch it took before the network.
    @Test("the epoch stands in the lock of the stock: swap, record, store, merge, and gpodder writes only through merge with its epoch", .needsTheSources)
    func theEpochLivesInTheStocksLock() throws {
        let store = try Self.code("Sources/Models/ListeningStore.swift")
        let replace = try #require(Self.body(of: "static func replaceForNewOwner(", in: store))
        let swap = try #require(replace.range(of: "withStock(defaults)"))
        let swapEnd = try #require(replace.range(of: "return (backups, flushed)"))
        #expect(replace[swap.upperBound..<swapEnd.lowerBound].contains("ownerEpochs.withLock"),
                "the epoch moves outside the lock of the swap")
        for name in ["static func record(", "static func store(", "static func merge("] {
            let body = try #require(Self.body(of: name, in: store), "\(name) is gone")
            let lock = try #require(body.range(of: "withStock(defaults)"), "\(name) writes past the stock's lock")
            #expect(body[lock.upperBound...].contains("holds(epoch"), "\(name) asks the epoch outside the lock of its write")
        }
        let gpodder = try Self.code("Sources/Networking/GPodderSync.swift")
        let round = try #require(Self.body(of: "private func syncEpisodeActions(", in: gpodder))
        #expect(!round.contains("ListeningStore.store("), "the gpodder round writes without its epoch")
        #expect(round.contains("ListeningStore.merge(play.guid, epoch: epoch)"), "the gpodder round does not merge with its epoch")
        let taken = try #require(round.range(of: "let epoch = ListeningStore.ownerEpoch()"))
        let network = try #require(round.range(of: "client.episodeActions("))
        #expect(taken.lowerBound < network.lowerBound, "the gpodder round takes its epoch after the network")
        // Red probe on the reader: a body ends where its braces close.
        #expect(Self.body(of: "func a(", in: "func a() { x { y } }\nfunc b() { z }") == "func a() { x { y } }")
    }

    /// A source file below the repository root, comment lines removed.
    static func code(_ relative: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(relative), encoding: .utf8))
    }

    /// The text of a declaration from its name to its closing brace.
    static func body(of declaration: String, in text: String) -> String? {
        guard let start = text.range(of: declaration),
              let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1; if depth == 0 { return String(text[start.lowerBound...index]) } }
            index = text.index(after: index)
        }
        return nil
    }
}
#endif
