// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// An archive carries no warning that a nonisolated place reads the main
/// actor: the probe archive of 3.10 (69) had one, from a static property a
/// nonisolated function read. The Release build of every full run is the
/// archive's compile; it stops on such a warning, so the count is 0 before
/// any archive is made.
struct ReleaseIsolationFenceTests {
    @Test("the Release build of the full run stops on an actor-isolated warning", .needsTheSources)
    func theReleaseBuildStopsOnTheWarning() throws {
        let script = try SourceTree.text(SourceTree.root.appendingPathComponent("scripts/lauf.sh"))
        let body = script.components(separatedBy: "release_symbols() {").dropFirst().first ?? ""
        #expect(body.contains("grep -c 'actor-isolated' \"$log\""), "the Release build does not count the warning")
        #expect(body.contains("actor-isolated im Release-Bau"), "the stop does not name the warning")
    }

    @Test("the side of a folder tile is read by its nonisolated rule without the main actor", .needsTheSources)
    func theWidestSideIsNonisolated() throws {
        let views = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastFolderViews.swift"))
        #expect(views.contains("nonisolated static let widestSide: CGFloat = 240"))
        #expect(PodcastFolderRow.side(forWidth: 10_000) == PodcastFolderRow.widestSide)
    }
}
#endif
