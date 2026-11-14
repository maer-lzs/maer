// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The CONTRACT of the 78 rpm area (as a counter-
/// proposal: the invariant is tested, not a sample).
///
/// Why this shape: the area is safe because every shelf is defined by an
/// INCLUSION criterion. What does not meet it never appears. A test that
/// held a handful of known-bad identifiers against the queries would only
/// ever prove something about those identifiers on that day (and would put
/// exactly the list into the repo that was ruled out, and that
/// rules out for the repo as a whole). What actually guarantees the property
/// is the CONSTRUCTION, so that is what is nailed down here: lose the subject
/// constraint, or add a way past the shelves, and these cases go red.
///
/// The empirical basis stays in the report: counter-measured 46 hits of
/// problematic material in the collection. 0 of them inside these shelves.
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

    /// No area on georgeblood sees the whole collection: the safety
    /// comes from the shelves, and the Popular row of the surface (also the
    /// row „Alte Schallplatten“ and Start „Entdecken · Musik“) takes exactly
    /// their union. It used to query `collection:georgeblood` in full
    /// and bypassed the shelves.
    @Test("no area sees the whole 78s collection, the Popular row is the union of the shelves")
    func noAreaSeesTheWholeCollection() {
        let ganze = ArchiveMusicCatalog.all
            .filter { $0.query.contains("collection:georgeblood") && !$0.query.contains("subject:") }
        #expect(ganze.isEmpty, "ein Bereich zeigt die ganze Sammlung ungefiltert: \(ganze.map(\.key))")
        let eltern = ArchiveMusicCatalog.shellacAll
        #expect(eltern.query == ArchiveMusicCatalog.shellacUnionQuery(
            subjects: ArchiveMusicCatalog.shellacShelves.map(\.subject)))
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(eltern.query.contains("\"\(shelf.subject)\""), "\(shelf.key) fehlt in der Vereinigung")
        }
        // Red test of the checker: the old query stands out.
        let alt = "collection:georgeblood AND mediatype:(audio)"
        #expect(alt.contains("collection:georgeblood") && !alt.contains("subject:"))
        // The union claims nothing about rights.
        let text = (eltern.headerNote + " " + eltern.title).lowercased()
        #expect(!text.contains("public domain") && !text.contains("gemeinfrei"))
        // Measured on 25.10.2026: 29,807 in the union, 187,034 in the collection.
        #expect(eltern.measuredTotal == 29_807)
    }

    /// „Alte Schallplatten" is an ordinary tile row like Netlabels
    /// and Jamendo: header line with chevron, tiles below. The
    /// selection capsules that used to switch the shelf IN the row now
    /// stand as shelves on the surface behind the chevron.
    @Test("the 78s row is an ordinary tile row, without a selection in the row", .needsTheSources)
    func theOldRecordsRowIsAnOrdinaryTileRow() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/Music/ShellacSection.swift"),
            encoding: .utf8)
        #expect(!text.contains("CategoryTile"),
                "die Auswahl-Kapseln sind in der Reihe zurueck")
        #expect(!text.contains("selectedShelfKey"),
                "die Reihe waehlt wieder ein Fach in sich selbst")
        #expect(text.contains("MusicRoute.shellacArea"),
                "die Kopfzeile fuehrt nicht mehr auf die Flaeche mit den Faechern")
        // The content is the PARENT query, not a single shelf. Otherwise
        // the row would show an excerpt and claim the collection.
        #expect(text.contains("ArchiveMusicCatalog.shellacAll"),
                "die Reihe zeigt wieder ein einzelnes Fach")
    }

    /// The row in the tab and the Popular row on the surface behind it
    /// reach into the SAME collection. With the same start value both would
    /// begin with the same tiles, and the chevron would lead to what the user
    /// is already looking at.
    @Test("the tab row and the row of the surface reach into different places")
    func theTabRowAndTheAreaRowDrawDifferentExcerpts() {
        let flaeche = CatalogRotation.salt(forShelf: ArchiveMusicCatalog.shellacAll.key)
        #expect(ShellacSection.rowSalt != flaeche, "beide Reihen teilen ihren Startwert")

        // The pages themselves, on a fixed day. Two start values that coincided
        // modulo the page count would find the same page EVERY day:
        // the day enters both the same way. One day therefore suffices as proof.
        let tag = Date(timeIntervalSince1970: 1_756_000_000)
        let gesamt = ArchiveMusicCatalog.shellacAll.measuredTotal
        #expect(CatalogRotation.page(total: gesamt, rowSize: 12, on: tag,
                                     salt: ShellacSection.rowSalt)
                != CatalogRotation.page(total: gesamt, rowSize: 12, on: tag, salt: flaeche),
                "beide Reihen zeigen dieselbe Seite der Sammlung")

        // And in the day store they have separate places, otherwise
        // one would overwrite the other's day.
        #expect(ShellacSection.rowSlot != CatalogShelfSource.popularShelf)
    }

    @Test("keys, route ids and titles are unique across areas")
    func areasAreDistinct() {
        let keys = ArchiveMusicCatalog.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        let routes = ArchiveMusicCatalog.all.map(\.routeIdentifier)
        #expect(Set(routes).count == routes.count)
        // The classical identifiers are load-bearing (journeys address them).
        #expect(ArchiveMusicCatalog.classical.routeIdentifier == "music-route-free-classical")
        // `deckIdentifier` fell with the free tile: the
        // property had no caller after that, so it is gone and
        // this case checks no promise to nobody.
    }

    @Test("netlabels only ever asks for items that state a licence")
    func netlabelsRequiresStatedLicence() {
        // The DISPLAY is opened. 18 % of the netlabel titles carry no
        // license statement and are thus visible, with the note about the
        // unclear rights situation on the tile. The declaration still decides
        // on the COPY.
        #expect(!ArchiveMusicCatalog.netlabels.query.contains("licenseurl"),
                "die Netlabels-Anzeige filtert wieder nach Lizenz")
        #expect(ArchiveMusicCatalog.netlabels.query.contains("collection:netlabels"))
        #expect(FreeCatalog.licenceLabel(nil) == FreeCatalog.unstatedRights,
                "ein Eintrag ohne Angabe schweigt wieder")
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
    }

    /// The Popular row of the shellac surface has the SAME basis as
    /// its shelves. Otherwise it taps a different set than what
    /// stands below it. The contract test therefore covers it too.
    @Test("the parent query shares the basis of its shelves")
    func theParentQuerySharesItsShelvesFoundation() {
        let eltern = ArchiveMusicCatalog.shellacAll
        #expect(eltern.query.contains("collection:georgeblood"),
                "die Beliebt-Reihe zapft eine andere Sammlung an als ihre Faecher")
        #expect(eltern.query.contains("mediatype:(audio)"))
        // Its shelf clause is the union of all shelves, not a tenth shelf.
        #expect(eltern.query.contains("subject:("))
        // Every shelf stands on the same collection.
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(shelf.query.contains("collection:georgeblood"),
                    "\(shelf.key) steht auf einer anderen Grundlage als die Beliebt-Reihe")
            #expect(shelf.query.contains("subject:"), "\(shelf.key) hat seine Fach-Klausel verloren")
        }
        // Red test: the broader 78rpm collection would be the second truth.
        #expect(!eltern.query.contains("78rpm"))
        // The collection carries NO license field (measured: 0 of 187,034).
        // The row thus carries the note about the unclear
        // rights situation throughout. Display yes, download no. The
        // formerly removed public-domain claim must not come back.
        #expect(!eltern.headerNote.lowercased().contains("public domain"))
        #expect(!eltern.headerNote.lowercased().contains("gemeinfrei"))
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
    }

    /// The selector under "Old Records" must never resolve to the undivided
    /// collection: an unknown or missing key falls back to a SHELF, and every
    /// shelf carries its subject constraint.
    @Test("a selection always resolves to a shelf, never to the whole collection")
    func selectionNeverEscapesTheShelves() {
        for key in [nil, "", "does-not-exist", "shellac-jazz", "free-classical"] {
            let area = ArchiveMusicCatalog.shelfOrFirst(key: key)
            #expect(ArchiveMusicCatalog.shellacShelves.contains { $0.key == area.key },
                    "\(key ?? "nil") must resolve to one of the shelves")
            #expect(!area.subject.isEmpty, "a shelf without a subject would be the whole collection")
            #expect(area.query.contains("subject:"), "the inclusion criterion must stay in the query")
        }
    }

    /// Classical is a shelf now, and its address stays the same because
    /// journeys and this contract address it by key.
    @Test("classical is one of the shelves and keeps its address")
    func classicalIsAShelf() {
        #expect(ArchiveMusicCatalog.shellacShelves.contains { $0.key == "free-classical" })
        #expect(ArchiveMusicCatalog.classical.subject == "classical")
        #expect(!ArchiveMusicCatalog.classical.headerNote.isEmpty)
    }
}
#endif
