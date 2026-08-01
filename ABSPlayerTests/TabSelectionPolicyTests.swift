// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Y37 hardening (01.08): only a REAL user deactivation moves the tab
/// selection — the availability race (async subscription load / pending
/// server probe / VPN-only server) must never throw the user off a tab.
struct TabSelectionPolicyTests {

    @Test("transient unavailability keeps the selection (the reported bug)")
    func transientUnavailabilityKeepsSelection() {
        // Podcasts selected, master toggle ON, but no source currently
        // "available" (subs still decoding, ABS probe failed without VPN):
        #expect(!TabSelectionPolicy.shouldFallBackToHome(selected: .podcasts, masterEnabled: true))
    }

    @Test("a real user deactivation falls back to Home")
    func userDeactivationFallsBack() {
        #expect(TabSelectionPolicy.shouldFallBackToHome(selected: .podcasts, masterEnabled: false))
        #expect(TabSelectionPolicy.shouldFallBackToHome(selected: .radio, masterEnabled: false))
    }

    @Test("Home never falls back")
    func homeNeverFallsBack() {
        #expect(!TabSelectionPolicy.shouldFallBackToHome(selected: .home, masterEnabled: true))
        #expect(!TabSelectionPolicy.shouldFallBackToHome(selected: .home, masterEnabled: false))
    }
}
#endif
