// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The countries of the radio play page are names the system already knows
/// in every language. Written as texts, each language had to translate 19
/// country names again, and one draft said Korea where the country is South
/// Korea.
struct OERRCountryNamesTests {
    @Test("every country of the radio play page takes its name from its code, in every language")
    func namesComeFromTheCode() throws {
        for language in ["en", "de", "fr", "ru", "uk"] {
            let locale = Locale(identifier: language)
            for country in OERRCuration.Country.allCases {
                let name = try #require(locale.localizedString(forRegionCode: country.code), "\(country.code)")
                #expect(country.title(in: locale) == name, "\(language) \(country.code)")
            }
        }
        #expect(Set(OERRCuration.Country.allCases.map(\.code)).count == OERRCuration.Country.allCases.count, "two countries share a code")
    }

    @Test("the country names are no texts of the catalog any more", .needsTheSources)
    func noCountryNameInTheCatalog() throws {
        let curation = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Models/OERRCuration.swift"))
        #expect(!curation.contains("String(localized:"), "the curation writes a country name as a text")
        let url = SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings")
        let strings = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        let names = ["Germany", "Austria", "Switzerland", "United Kingdom", "Australia", "Canada", "New Zealand", "France",
                     "Belgium", "Italy", "Spain", "Netherlands", "Sweden", "Norway", "Denmark", "Finland", "Portugal",
                     "Japan", "Korea"]
        #expect(names.filter { strings[$0] != nil }.isEmpty, "still in the catalog: \(names.filter { strings[$0] != nil })")
    }
}
#endif
