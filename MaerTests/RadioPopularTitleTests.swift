// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The national row names its country as a value after a colon, in every
/// language: a fixed preposition before a country's name breaks where the
/// name wants an article or another case ("Beliebt in Schweiz",
/// "Populaire en Canada", "Popolari in Paesi Bassi").
struct RadioPopularTitleTests {
    /// What stands before the country's name, per language. French sets a
    /// space before the colon, the plain one its catalog uses everywhere.
    static let heads = [
        "en": "Popular: ", "de": "Beliebt: ", "es": "Popular: ", "fr": "Populaire : ",
        "it": "Popolari: ",
    ]

    @Test("Switzerland, Canada, the Netherlands and the United States stand after a colon, without a preposition, in every language")
    func noPrepositionBeforeTheCountry() throws {
        for (language, head) in Self.heads.sorted(by: { $0.key < $1.key }) {
            let locale = Locale(identifier: language)
            for code in ["CH", "CA", "NL", "US"] {
                let name = try #require(locale.localizedString(forRegionCode: code))
                #expect(RadioPopularTitle.text(code: code, locale: locale) == head + name, "\(language) \(code)")
            }
        }
    }

    @Test("the row asks the rule, and the sentence with a preposition is gone from the catalog", .needsTheSources)
    func theRowAsksTheRule() throws {
        let view = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/Radio/RadioView.swift"))
        #expect(view.contains("RadioPopularTitle.text(code: code, locale: .current)"))
        let catalog = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        #expect(!catalog.contains("\"Popular in %@\""), "the old key with its preposition is still in the catalog")
    }
}
#endif
