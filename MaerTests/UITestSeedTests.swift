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
            let literal = Double(argument.replacingOccurrences(of: "_", with: ""))
            #expect((literal ?? 0) >= Self.year2000Ms, "a seeded lastUpdate is not milliseconds: \(argument)")
        }
    }
}
#endif
