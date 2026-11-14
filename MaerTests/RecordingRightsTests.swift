// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The computed public-domain limit for sound recordings: from the CURRENT year,
/// never hard-wired, with the staggered terms of the law.
struct RecordingRightsTests {

    @Test("the limit moves with the calendar, a hard year number would turn red")
    func theBoundaryMovesWithTheCalendar() {
        // 2026: public domain up to 1925 (100-year term as the longest).
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1925, currentYear: 2026))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1926, currentYear: 2026))

        // Red probe, as the decision requires: in the FOLLOWING YEAR the
        // limit moves. A hard-wired year number would not pass exactly this
        // line.
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1926, currentYear: 2027))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1927, currentYear: 2027))
    }

    @Test("the staggered terms are in the computation, not beside it")
    func theStepsAreInTheComputation() {
        // 1946 runs 100 years: free from 2047.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1946, currentYear: 2046))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1946, currentYear: 2047))
        // 1947 runs 110 years: free only from 2058. Without the staggered terms it
        // would be 2048, and exactly this gap is the probe.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2048))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2057))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2058))
        // 1957 to 1972 all end in 2067, as a date and not as a term.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1957, currentYear: 2067))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1957, currentYear: 2068))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1972, currentYear: 2068))
        // After that nothing is computed and nothing claimed here.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1973, currentYear: 2100))
    }

    @Test("without a year nothing is ever guessed, and nonsense does not count as a year")
    func withoutAYearNothingIsGuessed() {
        // The intake point computes only when `Int(prefix(4))` yields a year;
        // here the function side: an obvious non-value
        // never frees.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 0, currentYear: 2026))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 19, currentYear: 2026))
    }

    /// No tile carries a rights capsule, not even for netlabels:
    /// the archive's notice appears once at the top of every archive.org surface,
    /// the per-title statement on the detail page.
    @Test("no tile carries a rights capsule, every archive.org surface the one notice", .needsTheSources)
    func noTileCarriesARightsCapsule() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let tile = try source("Sources/Views/FeedArtwork.swift")
        #expect(!tile.contains("badgeText"), "the catalog tile carries a capsule again")
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            #expect(!code.contains("badgeText: entry.ccLicense") && !code.contains("hidesUnstatedRights"),
                    "\(name) puts a rights capsule on a tile")
        }
        // The notice tops every archive.org surface: the area page (netlabels
        // and shellac), the shellac surface, Old Time Radio and the archive books.
        #expect(try source("Sources/Views/Music/ArchiveMusicPages.swift")
            .components(separatedBy: "ArchiveRightsNote()").count - 1 == 2)
        #expect(try source("Sources/Views/CatalogSourcePage.swift")
            .contains("if source == .oldTimeRadio || source == .archiveBooks {\n                ArchiveRightsNote()"))
    }
}
