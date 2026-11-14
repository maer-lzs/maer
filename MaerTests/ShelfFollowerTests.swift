// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one way a family follows the account (`ShelfFollower` around
/// `RestingShelf.handOver`), on a family made up for the witness: its stock
/// is a value in memory, laid and replaced as the families do.
@MainActor
struct ShelfFollowerTests {
    struct Stock: Codable, Equatable {
        var items: [String] = []
    }

    /// A made-up family: its live stock, and what the mantle asks of it.
    final class Family {
        var live = Stock()
        var unread = false
        let follower: ShelfFollower
        init(shelf: RestingShelf) { follower = ShelfFollower(family: "made-up", shelf: shelf, label: "MADEUP") }

        func follow(_ scope: String, previous: String? = nil,
                    landing: ShelfFollower.Landing = .now,
                    landed: (String) throws -> Bool = { _ in false }) -> RestingShelf.HandOver? {
            follower.follow(to: scope, previous: previous, unread: unread, landing: landing, landed: landed,
                            current: { live }, replace: { rest, _, _ in live = rest ?? Stock() })
        }
    }

    private func shelf() throws -> (RestingShelf, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-follower-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (RestingShelf(directory: directory), { try? FileManager.default.removeItem(at: directory) })
    }

    @Test("an open replacement of an earlier run ends before anything is stored: B's rest without A, A stays with A")
    func anOpenReplacementEndsBeforeTheStockIsLaid() throws {
        let (shelf, cleanup) = try shelf()
        defer { cleanup() }
        let restOfA = Stock(items: ["a"])
        let restOfB = Stock(items: ["b"])
        try shelf.lay(restOfA, of: "made-up", owner: "account-a")
        try shelf.lay(restOfB, of: "made-up", owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "old"),
                             of: "made-up")
        let family = Family(shelf: shelf)
        family.live = restOfA   // the replacement of the run before never landed
        #expect(family.follow("account-c") == .moved)
        #expect(try shelf.rest(Stock.self, of: "made-up", owner: "account-b") == restOfB, "A's stock was laid as B's")
        #expect(try shelf.rest(Stock.self, of: "made-up", owner: "account-a") == restOfA)
        #expect(family.live == Stock(), "C starts with what rests for C: nothing")
        #expect(try shelf.holding(of: "made-up")?.owner == "account-c")
    }

    @Test("an unread stock holds every outcome, also with the same holder and after a change already held")
    func anUnreadStockHoldsEveryWayOut() throws {
        let (shelf, cleanup) = try shelf()
        defer { cleanup() }
        let family = Family(shelf: shelf)
        #expect(family.follow("account-a") == .first)
        #expect(family.follow("account-a") == .kept)
        family.unread = true
        #expect(family.follow("account-a") == .unread, "the holder unchanged let an unread stock through")
        family.unread = false
        #expect(family.follow("account-a") == .kept)
    }

    @Test("a handover whose holder does not settle tries again first the next time")
    func anUnsettledHoldingIsTriedAgain() throws {
        let (shelf, cleanup) = try shelf()
        defer { cleanup() }
        let family = Family(shelf: shelf)
        #expect(family.follow("account-a") == .first)
        family.live = Stock(items: ["a"])
        #expect(family.follow("account-b", landing: .marked) == .moved)
        let name = try #require(try shelf.holding(of: "made-up")?.replacement)
        // The holding cannot be written back when the rows land: settling fails.
        let holdingFile = shelf.directory.appendingPathComponent("made-up").appendingPathComponent("holding.json")
        let saved = try Data(contentsOf: holdingFile)
        try FileManager.default.removeItem(at: holdingFile)
        try FileManager.default.createDirectory(at: holdingFile, withIntermediateDirectories: true)
        family.follower.markLanded(name)
        try FileManager.default.removeItem(at: holdingFile)
        try saved.write(to: holdingFile)
        #expect(try shelf.holding(of: "made-up")?.replacing == true, "the precondition: the settle failed")
        #expect(family.follow("account-b") == .kept)
        #expect(try shelf.holding(of: "made-up") == .init(owner: "account-b"), "the unsettled holding was not tried again")
    }

    @Test("after a process end in the middle of a replacement only the mark counts: without it things are replaced and B gets nothing of A, with it B's stock stays")
    func onlyTheMarkProvesTheReplacementLanded() throws {
        let (shelf, cleanup) = try shelf()
        defer { cleanup() }
        let restOfA = Stock(items: ["a"])
        let restOfB = Stock(items: ["b"])
        try shelf.lay(restOfA, of: "made-up", owner: "account-a")
        try shelf.lay(restOfB, of: "made-up", owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "x"),
                             of: "made-up")
        // A wrote between laying and replacing, then the process ended: the
        // stock differs from A's rest, and it is A's.
        let restarted = Family(shelf: shelf)
        restarted.live = Stock(items: ["a", "a-later"])
        #expect(restarted.follow("account-b", landing: .marked, landed: { _ in false }) == .moved)
        #expect(restarted.live == restOfB, "a stock unlike A's rest was taken as landed: B holds A's")

        // With the mark the replacement landed: what stands is B's, kept.
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "y"),
                             of: "made-up")
        let marked = Family(shelf: shelf)
        marked.live = Stock(items: ["b", "b-later"])
        #expect(marked.follow("account-b", landing: .marked, landed: { $0 == "y" }) == .kept, "settling what landed reports a move")
        #expect(marked.live == Stock(items: ["b", "b-later"]), "a landed replacement was done again over B's writes")
        #expect(try shelf.holding(of: "made-up") == .init(owner: "account-b"))
    }

    @Test("handOver is called only from the wrapper", .needsTheSources)
    func handOverIsCalledFromTheMantleAlone() throws {
        var callers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains(".handOver(") { callers.append(file.lastPathComponent) }
        }
        #expect(callers == ["ShelfFollower.swift"], "\(callers)")
        #expect(SyncContractFenceTests.stripped("let step = try shelf.handOver(\n").contains(".handOver("),
                "the finder sees a call")
    }
}
#endif
