// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// The DEBUG-only UI-test seed must do NOTHING unless the process was launched
/// with `-uitest` — so a normal launch (and the whole test process) is
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
}
#endif
