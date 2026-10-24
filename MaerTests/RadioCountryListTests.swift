// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The country layer of the radio picker.
struct RadioCountryListTests {
    private let raw: [(code: String, name: String, count: Int)] = [
        ("DE", "Germany", 4000), ("AT", "Austria", 900), ("CH", "Switzerland", 700),
        ("AL", "Albania", 40), ("NO", "Norway", 300), ("VA", "Holy See", 1),
    ]
    private let german = ["DE": "Deutschland", "AT": "Österreich", "CH": "Schweiz", "AL": "Albanien",
                          "NO": "Norwegen", "VA": "Vatikanstadt"]

    @Test("die Laender stehen nach ihrem gezeigten Namen, nicht nach der Zahl der Sender; unter zwei Sendern faellt ein Land")
    func theCountriesStandByTheirShownName() {
        let list = RadioCountryList.curated(raw) { german[$0] }
        #expect(list.map(\.shown) == ["Albanien", "Deutschland", "Norwegen", "Österreich", "Schweiz"],
                "\(list.map(\.shown))")
        #expect(!list.contains { $0.code == "VA" }, "a country with one station stays out")
        #expect(list.first { $0.code == "AT" }?.name == "Austria", "the English name for the states endpoint stays")
        // Without a shown name the English one stands, and sorts with it.
        let english = RadioCountryList.curated(raw) { _ in nil }
        #expect(english.map(\.shown) == ["Albania", "Austria", "Germany", "Norway", "Switzerland"])
    }

    @Test("die Suche findet ein Land ueber beide Namen, ohne Akzente und Gross-Klein, nie ueber die Grenze der zwei Namen")
    func theSearchAsksBothNames() {
        let list = RadioCountryList.curated(raw) { german[$0] }
        #expect(RadioCountryList.filtered(list, query: "oster").map(\.code) == ["AT"])
        #expect(RadioCountryList.filtered(list, query: "AUSTR").map(\.code) == ["AT"])
        #expect(RadioCountryList.filtered(list, query: "schw").map(\.code) == ["CH"])
        #expect(RadioCountryList.filtered(list, query: "").count == list.count)
        // "Germany" + "Deutschland" never meet into "ydeut".
        #expect(RadioCountryList.filtered(list, query: "ydeut").isEmpty)
    }
}
#endif
