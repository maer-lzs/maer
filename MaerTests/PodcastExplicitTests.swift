// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The explicit mark of podcasts: one rule, one letter, on episode rows, the
/// episode page and the show page.
struct PodcastExplicitTests {
    @Test("eine Folge traegt das E nach ihrem eigenen Kennzeichen, ohne eines nach dem der Sendung")
    func theEpisodeTagWinsElseTheShow() {
        #expect(PodcastExplicit.marks(episode: true, show: false))
        #expect(!PodcastExplicit.marks(episode: false, show: true), "a clean episode of an explicit show")
        #expect(PodcastExplicit.marks(episode: nil, show: true))
        #expect(!PodcastExplicit.marks(episode: nil, show: nil))
        #expect(PodcastExplicit.marks(show: true) && !PodcastExplicit.marks(show: nil))
    }

    @Test("Zeile, Folgenseite und Sendung fragen die eine Regel, keine Stelle schreibt das E selbst", .needsTheSources)
    func everySurfaceAsksTheRule() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let row = try source("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(row.contains("PodcastExplicit.marks(episode: found.episode.explicit, show: found.show.explicit)"))
        #expect(try source("Sources/Views/Podcasts/PodcastShowView.swift").contains("ExplicitMark()"))
        #expect(try source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift").contains("PodcastExplicit.marks("))
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            #expect(!code.contains("Text(\"E\")") && !code.contains("? \"E\" :"), "\(name) writes the mark itself")
        }
    }
}
#endif
