// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The generated logo table answers for a station with a file that never
/// expires, so it is held to a stricter probe than the runtime's: the file
/// name names the station and nothing else, only generic words and digits
/// around it (`RadioLogoLookup.fileNamesOnlyTheLabel`). Measured: the
/// generator booked Wikidata files without a probe ("Ö 3" and four country
/// codes showed a football club, "DE" a car maker), and with the looser
/// probe of the runtime photos whose names held the station name (a stadium
/// for "WFUV", an interview for "All India Radio, Kolkata", the BBC logo for
/// every "Radio 1"). An entry that fails the probe stays only with a vouched
/// reason for exactly its file; a name under four characters never passes
/// the probe and always needs one.
struct RadioLogoDataFenceTests {
    @Test("Jeder Eintrag der Logo-Tabelle besteht die Probe der Tabelle oder steht mit Grund fuer genau seine Datei im Bestand")
    func everyLogoEntryCarriesItsNameOrAReason() {
        let table = RadioLogoData.commonsFiles
        #expect(table.count > 300, "the fence read the table")
        let unvouched = table.filter { name, file in
            !RadioLogoLookup.fileNamesOnlyTheLabel(file, label: name)
                && RadioLogoData.vouched[name]?.file != file
        }.map { "\($0.key) -> \($0.value)" }.sorted()
        #expect(unvouched.isEmpty, "entries that answer for another house: \(unvouched)")
        let stale = RadioLogoData.vouched.filter { name, entry in
            table[name] != entry.file || entry.reason.isEmpty
        }.map(\.key).sorted()
        #expect(stale.isEmpty, "vouched entries without their file or reason: \(stale)")
        let needless = RadioLogoData.vouched.filter { name, entry in
            RadioLogoLookup.fileNamesOnlyTheLabel(entry.file, label: name)
        }.map(\.key).sorted()
        #expect(needless.isEmpty, "vouched entries that pass the probe by themselves: \(needless)")
        // The probes themselves, at the cases of the findings.
        #expect(!RadioLogoLookup.fileCarriesLabel("Logo of Beşiktaş JK.svg", label: "Ö 3"))
        #expect(!RadioLogoLookup.fileCarriesLabel("Mercedes-Benz Logo 2010.svg", label: "DE"))
        #expect(RadioLogoLookup.fileCarriesLabel("Hitradio Ö3.svg", label: "Hitradio Ö3"))
        let foreign = [("WakeForest-GrovesStadium-WFUvsVT-2004-pregame.jpg", "WFUV"),
                       ("BBC Radio 1 2021.svg", "Radio 1"),
                       ("Antenne Tirol 1998 T-Shirt (detail).jpg", "Antenne Tirol"),
                       ("Logo Rock Antenne Österreich.svg", "Antenne Österreich"),
                       ("Logo of Sophia, West Virginia.svg", "Sophia")]
        for (file, name) in foreign {
            #expect(RadioLogoLookup.fileCarriesLabel(file, label: name), "the precondition: the runtime probe passes \(file)")
            #expect(!RadioLogoLookup.fileNamesOnlyTheLabel(file, label: name), "the table probe passes \(file) for \(name)")
        }
        #expect(RadioLogoLookup.fileNamesOnlyTheLabel("Bayern1-logo.svg", label: "Bayern 1"))
        #expect(RadioLogoLookup.fileNamesOnlyTheLabel("Hitradio Ö3.svg", label: "Hitradio Ö3"))
        #expect(RadioLogoLookup.fileNamesOnlyTheLabel("MNM Hits logo.webp", label: "MNM Hits"))
        #expect(RadioLogoLookup.fileNamesOnlyTheLabel("SWR3 Logo 2020.svg", label: "SWR3"))
    }

    /// The generator holds new entries to the same probe in Python; its
    /// words are the app's words.
    @Test("die generischen Woerter der Tabellen-Probe sind in der App und im Generator dieselben", .needsTheSources)
    func theGenericWordsAreTheGenerators() throws {
        let script = try String(contentsOf: SourceTree.root.appendingPathComponent("tools/radio-logo-data/generate.py"),
                                encoding: .utf8)
        let block = try #require(script.range(of: "GENERIC_EXTRA = {").flatMap { start in
            script.range(of: "}", range: start.upperBound..<script.endIndex).map { String(script[start.upperBound..<$0.lowerBound]) }
        })
        let words = Set(block.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        #expect(words.count > 10, "the fence read the set: \(words)")
        #expect(words == RadioLogoLookup.genericFileWords,
                "apart: \(words.symmetricDifference(RadioLogoLookup.genericFileWords).sorted())")
    }

    /// A key of a regional table names a region, not a station; searched as a
    /// name it booked a football club for "Bayern" and party logos for two
    /// states.
    @Test("kein Schluessel einer Regionen-Tabelle steht als Sender in der Logo-Tabelle", .needsTheSources)
    func noRegionKeyStandsInTheTable() throws {
        let cores = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/RadioListenerCores.swift"),
                               encoding: .utf8)
        let regions = cores.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\": [") else { return nil }
            return String(trimmed.dropFirst().dropLast(4))
        }
        #expect(regions.contains("Bayern") && regions.count >= 20, "the fence read the regional keys: \(regions.count)")
        let booked = regions.filter { RadioLogoData.commonsFiles[$0] != nil }
        #expect(booked.isEmpty, "regions booked as stations: \(booked)")
    }
}
#endif
