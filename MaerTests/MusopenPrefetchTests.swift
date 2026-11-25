// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A full reading of the catalog took 6.6 s, too long a pause at the end
/// of a movement. So it begins when a numbered movement begins and the
/// catalog is unread in this run; the end of the movement waits for that
/// one reading, or finds the catalog read.
@MainActor
struct MusopenPrefetchTests {
    static let movement = "Symphony No.3 in F major Op.90 - I. Allegro con brio"

    @Test("the start of a numbered movement begins exactly one reading; a second start does not begin another")
    func beginsOnce() async {
        let prefetch = MusopenPrefetch()
        var reads = 0
        prefetch.begin(title: Self.movement, readToEnd: false) { reads += 1; return true }
        #expect(prefetch.isReading, "the start of the movement began no reading")
        prefetch.begin(title: Self.movement, readToEnd: false) { reads += 1; return true }
        _ = await prefetch.result { reads += 1; return true }
        #expect(reads == 1)
    }

    @Test("no reading for a title without a movement number, nor for a catalog read in this run")
    func notForOthers() async {
        let prefetch = MusopenPrefetch()
        var reads = 0
        prefetch.begin(title: "Wiener Blut Op. 354", readToEnd: false) { reads += 1; return true }
        prefetch.begin(title: Self.movement, readToEnd: true) { reads += 1; return true }
        #expect(reads == 0)
        #expect(!prefetch.isReading)
    }

    @Test("the end of a movement while the reading runs waits for it and starts the next movement")
    func endWaitsForTheReading() async {
        let prefetch = MusopenPrefetch()
        var reads = 0
        var finishedReading = false
        prefetch.begin(title: Self.movement, readToEnd: false) {
            reads += 1
            try? await Task.sleep(for: .milliseconds(50))
            finishedReading = true
            return true
        }
        var started: [String] = []
        let outcome = await MusopenReload.run(
            title: Self.movement, readToEnd: false,
            read: { await prefetch.result { reads += 1; return true } },
            stillEnded: { true },
            resolve: { finishedReading ? "mso:2" : nil },
            start: { started.append($0) }, log: { _ in })
        #expect(reads == 1, "the end read a second time")
        #expect(started == ["mso:2"])
        #expect(outcome == .started("mso:2"))
    }

    @Test("Fence: the coordinator begins the reading when a Musopen title begins, and the end waits on it", .needsTheSources)
    func wiring() throws {
        let coordinator = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(coordinator.contains("musopenPrefetch.begin("))
        #expect(coordinator.contains("musopenPrefetch.result"))
    }
}
#endif
