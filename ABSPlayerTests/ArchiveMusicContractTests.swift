// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// The CONTRACT of the 78 rpm area (the reviewer 08.08., Auflage 2 — as a counter-
/// proposal: the invariant is tested, not a sample).
///
/// Why this shape: the area is safe because every shelf is defined by an
/// INCLUSION criterion — what does not meet it never appears. A test that
/// held a handful of known-bad identifiers against the queries would only
/// ever prove something about those identifiers on that day (and would put
/// exactly the list into the repo that the owner ruled out, and that 958d7d1
/// rules out for the repo as a whole). What actually guarantees the property
/// is the CONSTRUCTION, so that is what is nailed down here: lose the subject
/// constraint, or add a way past the shelves, and these cases go red.
///
/// The empirical basis stays in the report: the reviewer counter-measured 46 hits of
/// problematic material in the collection — 0 of them inside these shelves.
/// Re-measure when the shelf set changes.
struct ArchiveMusicContractTests {
    @Test("every 78s shelf is positively defined (collection + subject)")
    func shellacShelvesAreInclusive() {
        #expect(!ArchiveMusicCatalog.shellacShelves.isEmpty)
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(shelf.query.contains("collection:georgeblood"),
                    "a 78s shelf must stay inside the curated digitisation collection")
            #expect(shelf.query.contains("subject:\""),
                    "a 78s shelf without a subject constraint would be an undivided view")
            #expect(shelf.query.contains("mediatype:(audio)"))
        }
    }

    @Test("no area offers an undivided view of the 78s collection")
    func noUndividedShellacView() {
        // Auflage 1: an area on georgeblood is only ever a shelf. The
        // classical area is the historical shelf of the same collection and
        // carries its own subject, so it satisfies the same rule.
        for area in ArchiveMusicCatalog.all where area.query.contains("collection:georgeblood") {
            #expect(area.query.contains("subject:"),
                    "\(area.key) would show the whole collection unfiltered")
        }
    }

    @Test("keys, route ids and titles are unique across areas")
    func areasAreDistinct() {
        let keys = ArchiveMusicCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        let routes = ArchiveMusicCatalog.all.map(\.routeIdentifier)
        #expect(Set(routes).count == routes.count)
        // The classical identifiers are load-bearing (journeys address them).
        #expect(ArchiveMusicCatalog.classical.routeIdentifier == "music-route-free-classical")
        #expect(ArchiveMusicCatalog.classical.deckIdentifier == "music-free-classical")
    }

    @Test("netlabels only ever asks for items that state a licence")
    func netlabelsRequiresStatedLicence() {
        // Measured 08.08.: 76.950 audio items, 61.111 with `licenseurl` —
        // the row shows the licence per tile, so it must not fetch the rest
        // (mostly NC/ND, i.e. NOT public domain — guessing is not an option).
        #expect(ArchiveMusicCatalog.netlabels.query.contains("licenseurl:[* TO *]"))
        #expect(ArchiveMusicCatalog.netlabels.query.contains("collection:netlabels"))
    }
}
#endif
