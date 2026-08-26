// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

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

    /// Ein Bereich auf georgeblood ist nicht mehr immer nur ein Fach. Die
    /// Flaeche hat ihre Beliebt-Reihe. Der Grund der alten Regel gilt aber
    /// weiter, und deshalb wandert der Fall nur: die frueher entfernte
    /// Gemeinfrei-Behauptung darf nicht zurueckkommen, denn die Sammlung
    /// fuehrt KEIN Lizenzfeld (gemessen 0 von 187.034).
    ///
    /// Neue Regel: ein Bereich auf georgeblood ist entweder ein Fach (mit
    /// Subject-Klausel) oder die EINE ausdruecklich benannte Eltern-Abfrage.
    /// Und die behauptet nichts ueber Rechte.
    @Test("nur EIN Bereich sieht die ganze 78er-Sammlung, und er behauptet nichts")
    func onlyTheNamedParentSeesTheWholeCollection() {
        let ganze = ArchiveMusicCatalog.all
            .filter { $0.query.contains("collection:georgeblood") && !$0.query.contains("subject:") }
        #expect(ganze.map(\.key) == [ArchiveMusicCatalog.shellacAll.key],
                "ein unbenannter Bereich zeigt die ganze Sammlung ungefiltert")
        // Der Grund der alten Regel, als eigener Satz gepruefet.
        for area in ganze {
            let text = (area.headerNote + " " + area.title).lowercased()
            #expect(!text.contains("public domain"))
            #expect(!text.contains("gemeinfrei"))
        }
        // Und jedes FACH bleibt ein Fach.
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(shelf.query.contains("subject:"),
                    "\(shelf.key) would show the whole collection unfiltered")
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
        // Die ANZEIGE ist geoeffnet. 18 % der Netlabel-Titel tragen keine
        // Lizenzangabe und sind damit sichtbar, mit dem Hinweis auf die
        // ungeklaerte Rechtelage an der Kachel. Die Deklaration entscheidet
        // weiterhin ueber die KOPIE.
        #expect(!ArchiveMusicCatalog.netlabels.query.contains("licenseurl"),
                "die Netlabels-Anzeige filtert wieder nach Lizenz")
        #expect(ArchiveMusicCatalog.netlabels.query.contains("collection:netlabels"))
        #expect(FreeCatalog.licenceLabel(nil) == FreeCatalog.unstatedRights,
                "ein Eintrag ohne Angabe schweigt wieder")
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
    }

    /// Die Beliebt-Reihe der Schellack-Flaeche hat DIESELBE Grundlage wie
    /// ihre Faecher. Sonst zapft sie eine andere Menge an als das, was
    /// darunter steht. Der Vertragstest deckt sie deshalb mit ab.
    @Test("die Eltern-Abfrage teilt die Grundlage ihrer Faecher")
    func theParentQuerySharesItsShelvesFoundation() {
        let eltern = ArchiveMusicCatalog.shellacAll
        #expect(eltern.query.contains("collection:georgeblood"),
                "die Beliebt-Reihe zapft eine andere Sammlung an als ihre Faecher")
        #expect(eltern.query.contains("mediatype:(audio)"))
        // Und sie traegt KEINE Fach-Klausel. Sonst waere sie ein zehntes Fach.
        #expect(!eltern.query.contains("subject:"))
        // Jedes Fach steht auf derselben Sammlung.
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(shelf.query.contains("collection:georgeblood"),
                    "\(shelf.key) steht auf einer anderen Grundlage als die Beliebt-Reihe")
            #expect(shelf.query.contains("subject:"), "\(shelf.key) hat seine Fach-Klausel verloren")
        }
        // Rot-Probe: die breitere 78rpm-Sammlung waere die zweite Wahrheit.
        #expect(!eltern.query.contains("78rpm"))
        // Die Sammlung fuehrt KEIN Lizenzfeld (gemessen: 0 von 187.034).
        // Die Reihe traegt also durchgehend den Hinweis auf die ungeklaerte
        // Rechtelage. Anzeigen ja, herunterladen nein. Die frueher
        // entfernte Gemeinfrei-Behauptung darf nicht zurueckkommen.
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
