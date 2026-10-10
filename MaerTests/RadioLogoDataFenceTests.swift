// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The generated logo table answers for a station with a file that never
/// expires, so it is held to the probe the runtime puts on every booked
/// file: the file name carries the station name. Measured: the generator
/// booked Wikidata files without it, and "Ö 3" and four country codes showed
/// a football club, "DE" a car maker. An entry that fails the probe stays
/// only with a vouched reason for exactly its file; a name under four
/// characters never passes the probe and always needs one.
struct RadioLogoDataFenceTests {
    @Test("Jeder Eintrag der Logo-Tabelle besteht die Probe der Laufzeit oder steht mit Grund fuer genau seine Datei im Bestand")
    func everyLogoEntryCarriesItsNameOrAReason() {
        let table = RadioLogoData.commonsFiles
        #expect(table.count > 300, "the fence read the table")
        let unvouched = table.filter { name, file in
            !RadioLogoLookup.fileCarriesLabel(file, label: name)
                && RadioLogoData.vouched[name]?.file != file
        }.map { "\($0.key) -> \($0.value)" }.sorted()
        #expect(unvouched.isEmpty, "entries that answer for another house: \(unvouched)")
        let stale = RadioLogoData.vouched.filter { name, entry in
            table[name] != entry.file || entry.reason.isEmpty
        }.map(\.key).sorted()
        #expect(stale.isEmpty, "vouched entries without their file or reason: \(stale)")
        let needless = RadioLogoData.vouched.filter { name, entry in
            RadioLogoLookup.fileCarriesLabel(entry.file, label: name)
        }.map(\.key).sorted()
        #expect(needless.isEmpty, "vouched entries that pass the probe by themselves: \(needless)")
        // The probe itself, at the cases of the finding.
        #expect(!RadioLogoLookup.fileCarriesLabel("Logo of Beşiktaş JK.svg", label: "Ö 3"))
        #expect(!RadioLogoLookup.fileCarriesLabel("Mercedes-Benz Logo 2010.svg", label: "DE"))
        #expect(RadioLogoLookup.fileCarriesLabel("Hitradio Ö3.svg", label: "Hitradio Ö3"))
    }
}
#endif
