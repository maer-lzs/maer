// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A Musopen movement that ends while the catalog was not read in this run
/// (a restart, a start from the history or the mini player) reads the
/// catalog once, as its page does, and asks the one advance again: what
/// waits in Up Next still comes first, and nothing starts over a title the
/// listener began meanwhile. A failed read ends the work as before.
@MainActor
struct MusopenReloadTests {
    static let movement = "Symphony No.3 in F major Op.90 - I. Allegro con brio"

    @Test("the rule: a numbered movement reads the catalog only while it is unread in this run")
    func theRule() {
        #expect(MusopenOrder.needsReading(after: Self.movement, readToEnd: false))
        #expect(!MusopenOrder.needsReading(after: Self.movement, readToEnd: true), "read to its end: the work simply ends")
        #expect(!MusopenOrder.needsReading(after: "Wiener Blut Op. 354", readToEnd: false), "no movement, nothing to look for")
    }

    @Test("a reading stops after its limit of answers even when the source always points on")
    func theLimit() async {
        var asked = 0
        let reading = await MusopenPageReading.readAll(MusopenPageReading(), maxAnswers: 40, fetch: { cursor in
            asked += 1
            // A brake of the witness itself: past 100 the source ends, so a
            // reading without its limit fails here instead of turning forever.
            return (.loaded(items: [], fetched: 50),
                    asked >= 100 ? nil : MusopenCatalog.Cursor(category: 0, token: "t\(asked)"))
        }, show: { _ in })
        #expect(asked == 40, "answers asked: \(asked)")
        #expect(reading.cursor != nil, "the reading stopped at its limit, not at the end")
        #expect(MusopenCatalog.readingLimit == 40)
    }

    /// One run of the reload with its seams counted.
    struct Run {
        var reads = 0
        var started: [String] = []
        var lines: [String] = []
        var outcome: MusopenReload.Outcome = .notNeeded
    }

    static func run(readToEnd: Bool = false, title: String = movement, readSucceeds: Bool = true,
                    stillEnded: Bool = true, resolves: String? = "mso:2") async -> Run {
        var run = Run()
        run.outcome = await MusopenReload.run(
            title: title, readToEnd: readToEnd,
            read: { run.reads += 1; return readSucceeds },
            stillEnded: { stillEnded },
            resolve: { resolves },
            start: { run.started.append($0) },
            log: { run.lines.append($0) })
        return run
    }

    @Test("read once, the next movement found: it starts")
    func readsAndStarts() async {
        let run = await Self.run()
        #expect(run.reads == 1)
        #expect(run.started == ["mso:2"])
        #expect(run.outcome == .started("mso:2"))
    }

    @Test("what waits in Up Next comes first: the one advance answers it, and it starts instead of the movement")
    func upNextFirst() async {
        let run = await Self.run(resolves: "sub:song:9")
        #expect(run.started == ["sub:song:9"])
    }

    @Test("a title the listener began meanwhile: nothing starts")
    func superseded() async {
        let run = await Self.run(stillEnded: false)
        #expect(run.started.isEmpty)
        #expect(run.outcome == .superseded)
    }

    @Test("a failed read: nothing starts, the work ends as before")
    func readFails() async {
        let run = await Self.run(readSucceeds: false)
        #expect(run.started.isEmpty)
        #expect(run.outcome == .readFailed)
        #expect(run.lines.contains { $0.hasPrefix("MUSOPEN reload failed") }, "the end says why: \(run.lines)")
    }

    @Test("read, and still nothing follows: the work ends")
    func nothingFollows() async {
        let run = await Self.run(resolves: nil)
        #expect(run.started.isEmpty)
        #expect(run.outcome == .nothingFollows)
    }

    @Test("a read that still finds no movement is not repeated at the next end in this run")
    func noSecondRead() async {
        var readInThisRun = false
        var reads = 0
        for _ in 0..<2 {
            _ = await MusopenReload.run(
                title: Self.movement, readToEnd: readInThisRun,
                read: { reads += 1; readInThisRun = true; return true },
                stillEnded: { true }, resolve: { nil }, start: { _ in }, log: { _ in })
        }
        #expect(reads == 1)
    }

    @Test("not needed: a catalog read to its end or a title without movements reads nothing")
    func notNeeded() async {
        for run in [await Self.run(readToEnd: true), await Self.run(title: "Wiener Blut Op. 354")] {
            #expect(run.reads == 0 && run.started.isEmpty && run.outcome == .notNeeded)
        }
    }

    @Test("Fence: the end of a title asks the reload when the advance has nothing; the page reads through the one loader", .needsTheSources)
    func wiring() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let coordinator = try source("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(coordinator.contains("MusopenReload.run("), "the end of a movement never reads the catalog")
        let page = try source("Sources/Views/Music/MusopenViews.swift")
        #expect(page.contains("MusopenLoader.readAll("), "the page reads past the loader that notes the end")
        let loader = try source("Sources/ViewModels/MusopenLoader.swift")
        #expect(loader.contains("musopenReadToEnd = !reading.failed"), "a reading that ended without failure, at the end or at its limit, counts as read")
    }
}
#endif
