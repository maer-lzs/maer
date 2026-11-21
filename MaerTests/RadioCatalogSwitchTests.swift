// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The switch on the radio source page turns the Radio Browser directory
/// on and off (`radioEnabled`), so it is named after the catalog, not
/// after the tab.
struct RadioCatalogSwitchTests {
    @Test("Fence: the radio source page names its switch Radio Catalog, in English and German, and no longer the tab", .needsTheSources)
    func theSwitchIsNamedAfterTheCatalog() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/RadioSourceView.swift"), encoding: .utf8))
        #expect(page.contains("AppSwitch(\"Radio Catalog\", isOn: $enabled)"), "the switch has another name")
        #expect(!page.contains("Show Radio tab"))
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = strings["Radio Catalog"] as? [String: Any]
        let german = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == "Radio-Katalog")
        #expect(strings["Show Radio tab"] == nil, "the old name stays in the catalogue")
    }
}
#endif
