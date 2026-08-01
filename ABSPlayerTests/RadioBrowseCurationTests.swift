// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Radio-Picker-Kuratierung (b942da6) against the REAL Swiss raw data
/// (`Fixtures/RadioCatalog/ch-states.json`, Radio Browser 01.08.2026 — 35
/// community entries incl. " Zürich" with a leading space, cities, and
/// foreign junk like "Burgenland"/"Saarland").
struct RadioBrowseCurationTests {

    private func swissRaw() throws -> [RadioBrowseEntry] {
        struct RBState: Decodable { let name: String; let stationcount: Int }
        let data = try CorpusFixture.data("ch-states", ext: "json", subdirectory: "RadioCatalog")
        return try JSONDecoder().decode([RBState].self, from: data)
            .map { RadioBrowseEntry(name: $0.name, stationCount: $0.stationcount) }
    }

    @Test("CH: variants merge — ' Zürich'(2) + 'Zürich'(40) become ONE entry, raw names kept for the query")
    func swissZurichMerge() throws {
        let curated = RadioBrowseCuration.curated(try swissRaw())
        let zurich = try #require(curated.first { $0.display == "Zürich" })
        #expect(zurich.stationCount == 42)
        // BOTH raw spellings survive — bystateexact matches byte-exactly,
        // dropping the padded variant would silently lose its 2 stations.
        #expect(Set(zurich.queryNames) == [" Zürich", "Zürich"])
        #expect(curated.filter { RadioBrowseCuration.mergeKey($0.display) == "zurich" }.count == 1)
    }

    @Test("CH: noise below the threshold is gone (cities/one-offs), keepers stay")
    func swissNoiseFilter() throws {
        let curated = RadioBrowseCuration.curated(try swissRaw())
        let names = Set(curated.map(\.display))
        // One-station entries dropped: city, orphan canton spellings, junk.
        for gone in ["Aarau", "Lausanne", "Winterthur", "NE", "solothurn",
                     "Canton of Vaud", "Saarland", "Basel-Landschaft"] {
            #expect(!names.contains(gone), "\(gone) must be filtered")
        }
        // Real regions with enough stations stay.
        for kept in ["Bern", "Basel", "Ticino", "Aargau", "Vaud", "Suisse Romande"] {
            #expect(names.contains(kept), "\(kept) must stay")
        }
        // 35 raw → 20 curated with the default threshold.
        #expect(curated.count == 20)
    }

    @Test("CH: sorted by merged station count desc, ties alphabetical")
    func swissSort() throws {
        let curated = RadioBrowseCuration.curated(try swissRaw())
        #expect(curated.first?.display == "Zürich")          // 42 after merge
        #expect(curated[1].display == "Suisse Romande")      // 40
        let counts = curated.map(\.stationCount)
        #expect(counts == counts.sorted(by: >))
        // Tie block (5): Aargau · Kanton Bern · Sankt Gallen · St. Gallen alphabetical.
        let five = curated.filter { $0.stationCount == 5 }.map(\.display)
        #expect(five == five.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test("Junk rules: empty, whitespace-only and purely numeric names never survive")
    func junkNames() {
        let curated = RadioBrowseCuration.curated([
            RadioBrowseEntry(name: "", stationCount: 99),
            RadioBrowseEntry(name: "   ", stationCount: 99),
            RadioBrowseEntry(name: "12345", stationCount: 99),
            RadioBrowseEntry(name: "Valid", stationCount: 3),
        ])
        #expect(curated.map(\.display) == ["Valid"])
    }

    @Test("Search filter: case-/diacritic-insensitive substring; no hit → empty (free text selects nothing)")
    func searchFilter() throws {
        let curated = RadioBrowseCuration.curated(try swissRaw())
        #expect(RadioBrowseCuration.filtered(curated, query: "zur").map(\.display) == ["Zürich"])
        #expect(RadioBrowseCuration.filtered(curated, query: "GALLEN").count == 2)
        #expect(RadioBrowseCuration.filtered(curated, query: "xyzzy").isEmpty)
        #expect(RadioBrowseCuration.filtered(curated, query: " ").count == curated.count)
    }

    @Test("Country cascade: explicit choice > region-implied > locale")
    func countryCascade() {
        #expect(RadioCountryCascade.effectiveCode(explicit: "CH", regionImplied: "DE", locale: "DE") == "CH")
        #expect(RadioCountryCascade.effectiveCode(explicit: nil, regionImplied: "CH", locale: "DE") == "CH")
        #expect(RadioCountryCascade.effectiveCode(explicit: "", regionImplied: nil, locale: "DE") == "DE")
        #expect(RadioCountryCascade.effectiveCode(explicit: nil, regionImplied: nil, locale: nil) == nil)
    }
}
#endif
