// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import SwiftUI
@testable import ABSPlayer

/// X24: the bottom bar's cover accent survives restarts — RGBA components
/// round-trip through UserDefaults, and a restored loader reports `hasAccent`.
@MainActor
struct CoverAccentPersistenceTests {
    @Test("RGBA components round-trip losslessly enough for a tint")
    func componentsRoundTrip() {
        let original = Color(red: 0.42, green: 0.13, blue: 0.77, opacity: 1)
        let comps = CoverColorLoader.components(of: original)
        #expect(comps.count == 4)
        let restored = CoverColorLoader.color(fromComponents: comps)
        #expect(restored != nil)
        #expect(CoverColorLoader.components(of: restored!)
                    .elementsEqual(comps, by: { abs($0 - $1) < 0.001 }))
        // Malformed input never crashes, just yields nil.
        #expect(CoverColorLoader.color(fromComponents: []) == nil)
        #expect(CoverColorLoader.color(fromComponents: [0.1, 0.2]) == nil)
    }

    @Test("a loader with a persisted accent restores it and reports hasAccent")
    func restoresPersistedAccent() {
        let key = "test.bottomBarAccent.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // First run: nothing persisted → neutral state.
        #expect(CoverColorLoader(persistenceKey: key).hasAccent == false)
        // Persist an accent, then "relaunch".
        UserDefaults.standard.set([0.9, 0.5, 0.1, 1.0], forKey: key)
        let relaunched = CoverColorLoader(persistenceKey: key)
        #expect(relaunched.hasAccent)
        #expect(CoverColorLoader.components(of: relaunched.accent)
                    .elementsEqual([0.9, 0.5, 0.1, 1.0], by: { abs($0 - $1) < 0.001 }))
    }
}
#endif
