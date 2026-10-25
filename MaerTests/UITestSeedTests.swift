// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The DEBUG-only UI-test seed must do NOTHING unless the process was launched
/// with `-uitest`. So a normal launch (and the whole test process) is
/// unaffected. In Release the type does not exist at all (#if DEBUG).
@MainActor
struct UITestSeedTests {
    @Test("without -uitest the seed is inactive and applyIfRequested is a no-op")
    func inactiveWithoutArgument() {
        // The unit-test process is not launched with -uitest.
        #expect(UITestSeed.isActive == false)
        let loggedInBefore = AppSession.shared.authViewModel.isLoggedIn
        UITestSeed.applyIfRequested()
        #expect(AppSession.shared.authViewModel.isLoggedIn == loggedInBefore)
    }

    /// Milliseconds since 1970 for the year 2000: no seeded progress lies
    /// before it, so a value given in seconds shows at once.
    nonisolated static let year2000Ms: Double = 946_684_800_000

    @Test("a seeded moment is in milliseconds like the server's")
    func seededMomentsAreMilliseconds() {
        let now = Date().timeIntervalSince1970 * 1000
        let monthAgo = UITestSeed.msAgo(35 * 24 * 3600)
        #expect(monthAgo > Self.year2000Ms)
        #expect(abs((now - monthAgo) - 35 * 24 * 3600 * 1000) < 60_000)
    }

    @Test("no seeded progress lies before 2000", .needsTheSources)
    func noSeededProgressBefore2000() throws {
        let seed = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/UITestSeed.swift"), encoding: .utf8)
        let arguments = seed.components(separatedBy: "lastUpdate: ").dropFirst()
            .map { String($0.prefix(while: { $0 != ")" && $0 != "," })) }
        #expect(!arguments.isEmpty)
        for argument in arguments {
            if argument.hasPrefix("msAgo(") { continue }
            // The detail a seeded book answers with copies the moment of its
            // own seeded progress, which this loop checks where it is set.
            if argument == "progress.lastUpdate" { continue }
            let literal = Double(argument.replacingOccurrences(of: "_", with: ""))
            #expect((literal ?? 0) >= Self.year2000Ms, "a seeded lastUpdate is not milliseconds: \(argument)")
        }
    }

    /// A server sends a progress with its time; a seeded one without it
    /// starts the player at 0 while Continue shows the fraction.
    @Test("jeder geseedete Stand traegt seine Zeit wie ein Server", .needsTheSources)
    func everySeededProgressCarriesItsTime() throws {
        let seed = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/UITestSeed.swift"), encoding: .utf8)
        // Each call ends with `))` (its own and the entry's); a single `)`
        // closes `msAgo(…)` inside it.
        let calls = seed.components(separatedBy: "BookProgress(").dropFirst()
            .map { $0.components(separatedBy: "))").first ?? "" }
        #expect(calls.count == 4, "the fence read the seeded progresses: \(calls.count)")
        for call in calls {
            #expect(call.contains("currentTime:"), "a seeded progress without its time: \(call)")
        }
        // Every seeded book has a track as long as itself, so a position lands.
        #expect(seed.contains("contentUrl: seedBookAudioURL"))
        // The detail the player starts from carries the same progress.
        #expect(seed.contains("userMediaProgress: entry.progress.map { progress in"))
        #expect(!seed.contains("userMediaProgress: nil)) }"), "the seeded detail knows no position again")
    }
}
#endif
