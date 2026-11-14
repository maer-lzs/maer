// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The app shows no scroll bars, on every device and in every posture. One
/// place says so (`noScrollBars`), the root and every presented leaf carry
/// it with the appearance, and no view decides for itself.
struct NoScrollBarsFenceTests {
    @Test("the scroll bars are set in one place, root and leaves carry them, no view decides by itself", .needsTheSources)
    func oneRuleForScrollBars() throws {
        var setters: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            let count = code.components(separatedBy: "scrollIndicators(").count - 1
                + code.components(separatedBy: "showsIndicators:").count - 1
            if count > 0 { setters.append("\(name): \(count)") }
        }
        #expect(setters == ["AppearanceHost.swift: 1"], "a view sets its scroll bars itself: \(setters)")
        let host = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/AppearanceHost.swift"), encoding: .utf8))
        #expect(host.contains(".preferredColorScheme(Self.scheme(AppearanceChoice.of(appearance)))\n            .noScrollBars()"))
        // The leaf that keeps its own scheme carries the rule itself.
        let library = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        #expect(library.contains("DriveModeView(coordinator: playerCoordinator, libraryViewModel: viewModel)\n                .noScrollBars()"))
    }
}
#endif
