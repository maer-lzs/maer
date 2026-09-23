// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// There is exactly one mapping from an episode to an entry, and it lives
/// below the views. Both podcast providers kept a private copy, field for
/// field the same as the one in the view layer; a copy that drifts gives
/// the same episode two faces depending on who asked.
///
/// The fence counts by SIGNATURE, not by name: a function that takes a show
/// and an episode and returns an entry is a mapping, whatever it is called.
struct EpisodeMappingFenceTests {
    /// Every function in a text that maps a show and an episode to an entry.
    nonisolated static func mappings(in text: String) -> Int {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
        let pattern = #/func\s+\w+\s*\([^)]*:\s*PodcastShow\s*,[^)]*:\s*PodcastEpisode\s*\)\s*->\s*LibraryItem\b/#
        return code.matches(of: pattern).count
    }

    @Test("der Zaehler erkennt eine Abbildung an ihrer Form, nicht an ihrem Namen")
    func theCounterKnowsAMappingByItsShape() {
        #expect(Self.mappings(in: "private func libraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {") == 1)
        #expect(Self.mappings(in: "static func entry(_ s: PodcastShow,\n    _ e: PodcastEpisode) -> LibraryItem {") == 1)
        #expect(Self.mappings(in: "func detail(show: PodcastShow, episode: PodcastEpisode) -> LibraryItemDetail {") == 0,
                "ein Detail ist keine Eintrags-Abbildung")
        #expect(Self.mappings(in: "// func old(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem") == 0)
    }

    @Test("genau eine Abbildung Folge zu Eintrag, und sie liegt in Models", .needsTheSources)
    func exactlyOneMappingBelowTheViews() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String] = []
        for file in files {
            let count = Self.mappings(in: try String(contentsOf: file, encoding: .utf8))
            let place = file.path.components(separatedBy: "/Sources/").last ?? file.lastPathComponent
            found += Array(repeating: place, count: count)
        }
        #expect(found == ["Models/PodcastEpisodeItem.swift"], "Abbildungen Folge zu Eintrag: \(found)")
    }
}
#endif
