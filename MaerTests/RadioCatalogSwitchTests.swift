// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The Radio Browser directory has one switch, on the radio card of the
/// sources, named Radio Catalog after what it turns on. The radio page
/// carries the stations entered by hand under Your Own Stations. With the
/// catalog off, the search still finds saved and own stations; only the
/// directory is not asked.
@MainActor
@Suite(.serialized)
struct RadioCatalogSwitchTests {
    @Test("the search of radio: off without the tab, own and saved stations with the tab, the directory only with the catalog")
    func searchScope() {
        #expect(RadioSearchRule.scope(tabOn: false, catalogOn: true) == .off)
        #expect(RadioSearchRule.scope(tabOn: false, catalogOn: false) == .off)
        #expect(RadioSearchRule.scope(tabOn: true, catalogOn: false) == .ownStations)
        #expect(RadioSearchRule.scope(tabOn: true, catalogOn: true) == .withCatalog)
    }

    @Test("with the catalog off a search finds an own station and asks no directory")
    func ownStationWithCatalogOff() async throws {
        let name = "Hofsender \(UUID().uuidString.prefix(6))"
        let station = try #require(RadioMapping.manualStation(name: name, urlString: "https://stream.example/hof"))
        RadioStore.addManual(station)
        defer { RadioStore.removeManual(station.id) }
        let found = try await RadioProvider.shared.searchStations(query: name, scope: .ownStations)
        #expect(found.map(\.id) == [station.id])
    }

    @Test("Fence: one switch, on the card, named Radio Catalog; the page has none and names its list Your Own Stations; the search asks the rule", .needsTheSources)
    func oneSwitchOnTheCard() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let card = try code("Sources/Views/SourceMapCard.swift")
        #expect(card.contains("sourceToggle(\"Radio Catalog\", isOn: $radioOn)"))
        let page = try code("Sources/Views/RadioSourceView.swift")
        #expect(!page.contains("AppSwitch("), "the radio page carries a switch of its own")
        #expect(page.contains("Text(\"Your Own Stations\")"))
        #expect(try code("Sources/ViewModels/SearchDoor.swift").contains("RadioSearchRule.scope("), "the bar does not ask the rule")
        #expect(try code("Sources/ViewModels/GlobalSearchModel.swift").contains("RadioSearchRule.scope("), "the search does not ask the rule")
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        func german(_ key: String) -> String? {
            let entry = strings[key] as? [String: Any]
            return (((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(german("Radio Catalog") == "Radio-Katalog")
        #expect(german("Your Own Stations") == "Eigene Radiosender")
        for gone in ["Show Radio tab", "Internet radio", "My Streams"] {
            #expect(strings[gone] == nil, "\(gone) stays in the catalogue")
        }
    }
}
#endif
