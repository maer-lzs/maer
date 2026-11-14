// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The folded iPhone Duo stays upright; open, on an iPhone and an iPad the
/// window keeps its orientations.
struct FoldOrientationTests {
    @Test("folded only upright, open and without a hinge as before")
    func onlyTheClosedHingeLocks() {
        #expect(FoldOrientation.uprightOnly(hingeClosed: true))
        #expect(!FoldOrientation.uprightOnly(hingeClosed: false))
        #expect(!FoldOrientation.uprightOnly(hingeClosed: nil))
    }

    @Test("the scene asks the rule, reads the hinge and reports every change", .needsTheSources)
    func theSceneAsksTheRule() throws {
        let app = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/MaerApp.swift"), encoding: .utf8))
        #expect(app.contains("func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {"))
        #expect(app.contains("if FoldOrientation.uprightOnly(hingeClosed: hingeClosed) { return .portrait }"))
        #expect(app.contains("UIHingeInteraction {"))
        #expect(app.contains("setNeedsUpdateOfSupportedInterfaceOrientations()"),
                "a change of the hinge does not ask the system again")
    }
}
#endif
