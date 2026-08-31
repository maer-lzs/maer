// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Radio-Picker-Kuratierung against the REAL Swiss raw data
/// (`Fixtures/RadioCatalog/ch-states.json`, Radio Browser 01.08.2026. 35
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
        // BOTH raw spellings survive. Bystateexact matches byte-exactly,
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

    @Test("cd5cc4a: DE canon — aliases pool onto one entry, raw names kept for bystateexact")
    func canonAliases() {
        let raw = [
            RadioBrowseEntry(name: "NRW", stationCount: 12),
            RadioBrowseEntry(name: "North Rhine-Westphalia", stationCount: 20),
            RadioBrowseEntry(name: "Nordrhein-Westfalen", stationCount: 8),
            RadioBrowseEntry(name: "Nordrhein Westfalen", stationCount: 2),
            RadioBrowseEntry(name: "Bavaria", stationCount: 15),
            RadioBrowseEntry(name: "Germany", stationCount: 99),
            RadioBrowseEntry(name: "Elsass", stationCount: 3),
        ]
        let curated = RadioRegionCanon.curated(raw, countryCode: "DE", otherLabel: "Other")!
        // NRW pools all four variants; every RAW name survives for bystateexact.
        let nrw = curated.first { $0.display == "Nordrhein-Westfalen" }
        #expect(nrw?.stationCount == 42)
        #expect(Set(nrw?.queryNames ?? []) == ["NRW", "North Rhine-Westphalia", "Nordrhein-Westfalen", "Nordrhein Westfalen"])
        #expect(curated.first { $0.display == "Bayern" }?.queryNames == ["Bavaria"])
        // Nationwide pseudo-state drops entirely; unmapped pools into Other (last).
        #expect(!curated.contains { $0.queryNames.contains("Germany") })
        #expect(curated.last?.display == "Other")
        #expect(curated.last?.queryNames == ["Elsass"])
        // Count-desc among canon entries.
        #expect(curated.first?.display == "Nordrhein-Westfalen")
    }

    @Test("cd5cc4a: canon fallback — no table means nil (generic curation stays)")
    func canonFallback() {
        let raw = [RadioBrowseEntry(name: "Bretagne", stationCount: 5)]
        #expect(RadioRegionCanon.curated(raw, countryCode: "FR", otherLabel: "Other") == nil)
        #expect(RadioRegionCanon.curated(raw, countryCode: nil, otherLabel: "Other") == nil)
        // CH umlaut/language variants meet their canton.
        let ch = RadioRegionCanon.curated([
            RadioBrowseEntry(name: "Geneva", stationCount: 4),
            RadioBrowseEntry(name: "Genève", stationCount: 6),
            RadioBrowseEntry(name: " Zürich", stationCount: 9),
        ], countryCode: "CH", otherLabel: "Other")!
        #expect(ch.first { $0.display == "Genf" }?.stationCount == 10)
        #expect(ch.first { $0.display == "Zürich" }?.queryNames == [" Zürich"])
    }

    @Test("cd5cc4a: favicon gate — size bounds and placeholder initials")
    func faviconGate() {
        #expect(RadioFaviconGate.acceptable(pixelWidth: 64, pixelHeight: 64))
        #expect(RadioFaviconGate.acceptable(pixelWidth: 512, pixelHeight: 64))
        #expect(!RadioFaviconGate.acceptable(pixelWidth: 63, pixelHeight: 512))
        #expect(!RadioFaviconGate.acceptable(pixelWidth: 16, pixelHeight: 16))
        #expect(RadioFaviconGate.initials(for: "Radio Paradise") == "RP")
        #expect(RadioFaviconGate.initials(for: "104.6 RTL") == "1R")
        #expect(RadioFaviconGate.initials(for: "SWR3") == "S")
        #expect(RadioFaviconGate.initials(for: "rock-antenne/hamburg") == "RA")
        #expect(RadioFaviconGate.initials(for: "  ") == nil)
        #expect(RadioFaviconGate.initials(for: "***") == nil)
    }

    @Test("Country cascade: explicit choice > region-implied > locale")
    func countryCascade() {
        #expect(RadioCountryCascade.effectiveCode(explicit: "CH", regionImplied: "DE", locale: "DE") == "CH")
        #expect(RadioCountryCascade.effectiveCode(explicit: nil, regionImplied: "CH", locale: "DE") == "CH")
        #expect(RadioCountryCascade.effectiveCode(explicit: "", regionImplied: nil, locale: "DE") == "DE")
        #expect(RadioCountryCascade.effectiveCode(explicit: nil, regionImplied: nil, locale: nil) == nil)
    }

    @Test("eindampfen: measured DE list — Other share drops below 10 %")
    func eindampfenMeasured() throws {
        // The REAL Radio-Browser DE states list (fetched 03.08.2026,
        // 167 entries / 3221 stations. The measurement IS the fixture).
        let data = try CorpusFixture.data("de-states-live", ext: "json", subdirectory: "RadioCatalog")
        struct Wire: Decodable { let name: String; let stationcount: Int }
        let raw = try JSONDecoder().decode([Wire].self, from: data)
            .map { RadioBrowseEntry(name: $0.name, stationCount: $0.stationcount) }
        let total = raw.reduce(0) { $0 + $1.stationCount }
        let curated = try #require(RadioRegionCanon.curated(raw, countryCode: "DE", otherLabel: "Other"))
        let other = curated.first { $0.display == "Other" }?.stationCount ?? 0
        // Measured before the subregion stage: 390/3221 = 12 %. Target < 10 %.
        #expect(Double(other) / Double(total) < 0.10,
                "Other holds \(other)/\(total) stations")
        // Composed names assign to exactly ONE state…
        let nrw = curated.first { $0.display == "Nordrhein-Westfalen" }
        #expect(nrw?.queryNames.contains("Deutschland und NRW") == true)
        let by = curated.first { $0.display == "Bayern" }
        #expect(by?.queryNames.contains { $0.hasPrefix("Bayern, München") } == true)
        // …ambiguous combos stay honestly in Other.
        let otherNames = curated.first { $0.display == "Other" }?.queryNames ?? []
        #expect(otherNames.contains("Berlin-Brandenburg"))
        #expect(otherNames.contains("SN, ST, TH"))
        // National-only decorations drop entirely.
        #expect(!curated.flatMap(\.queryNames).contains("Deutschland (Germany)"))
    }
}
#endif