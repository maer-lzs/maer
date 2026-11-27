// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The guide "A name for home and away": one address for a server at home
/// and on the road, in the server guides of the app and in docs, en, de, fr.
struct HomeAndAwayGuideTests {
    @Test("Fence: the server guides offer the guide, and its page names the three ways", .needsTheSources)
    func inTheApp() throws {
        let section = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/ServerGuidesSection.swift"), encoding: .utf8))
        #expect(section.contains("HomeAndAwayGuidePage()"))
        let page = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/HomeAndAwayGuidePage.swift"), encoding: .utf8))
        for key in ["Split DNS", "Tailscale", "reverse proxy"] {
            #expect(page.contains(key), "\(key) missing")
        }
    }

    @Test("the guide stands in docs in three languages", .needsTheDocs)
    func inDocs() throws {
        for name in ["home-and-away.md", "home-and-away.de.md", "home-and-away.fr.md"] {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent("docs/\(name)"), encoding: .utf8)
            #expect(text.contains("Tailscale") && text.contains("WireGuard"), "\(name)")
        }
    }
}
#endif
