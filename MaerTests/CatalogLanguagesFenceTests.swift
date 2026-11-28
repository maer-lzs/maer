// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every value of the three string catalogs, in every language, plural form
/// and Siri phrase, so a fence over the texts reads each language alike and
/// not German alone.
nonisolated enum CatalogValues {
    struct Value: Equatable {
        let catalog: String
        let key: String
        let language: String
        /// The plural form, or the place of a Siri phrase; empty for a plain text.
        let part: String
        let text: String
    }

    static let catalogs = ["Localizable", "AppShortcuts", "InfoPlist"]

    /// The values of one catalog's `strings`, English keys left out.
    static func values(catalog: String, strings: [String: Any]) -> [Value] {
        var out: [Value] = []
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            for (language, rawLocalization) in localizations {
                guard let localization = rawLocalization as? [String: Any] else { continue }
                if let unit = localization["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                    out.append(Value(catalog: catalog, key: key, language: language, part: "", text: text))
                }
                let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
                for (form, rawForm) in plural {
                    if let text = ((rawForm as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                        out.append(Value(catalog: catalog, key: key, language: language, part: form, text: text))
                    }
                }
                let phrases = (localization["stringSet"] as? [String: Any])?["values"] as? [String] ?? []
                for (index, text) in phrases.enumerated() {
                    out.append(Value(catalog: catalog, key: key, language: language, part: "\(index + 1)", text: text))
                }
            }
        }
        return out
    }

    /// Every value of the three catalogs in the source tree.
    static func all() throws -> [Value] {
        try catalogs.flatMap { name in
            let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/\(name).xcstrings"))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return values(catalog: name, strings: json?["strings"] as? [String: Any] ?? [:])
        }
    }

    /// The placeholders of a text by kind, position numbers left out: the
    /// same rule the import of `scripts/l10n.py` refuses a cell by.
    static func placeholders(_ text: String) -> [String] {
        text.matches(of: #/%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|q|z|t|j)?[@dDuUxXoOfeEgGcCsSaAp]|\$\{\w+\}/#)
            .map { String($0.output).replacing(#/^%\d+\$/#, with: "%") }
            .sorted()
    }
}

struct CatalogLanguagesFenceTests {
    /// The languages the project knows: English as the key, German kept in
    /// Xcode, and the three a translation comes back for.
    nonisolated static let regions = ["en", "de", "Base", "es", "fr", "it"]

    @Test("the project knows English, German, Spanish, French and Italian", .needsTheProjectFile)
    func theProjectKnowsTheLanguages() throws {
        let project = try String(contentsOf: SourceTree.root.appendingPathComponent("Maer.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let block = try #require(project.firstMatch(of: #/knownRegions = \(([^)]*)\);/#)?.output.1)
        let regions = block.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        #expect(regions == Self.regions, "knownRegions: \(regions)")
    }

    /// The texts with a counted number that a language says in one form
    /// for every count, measured. A text that gains its forms leaves the
    /// stock, a new one without forms grows it; both show here. 69: the
    /// gpodder counts positions in and out became positions received and
    /// sent, which carry their forms. 63: six sentences carried a code as
    /// their number (server error, HTTP); the code now stands behind the
    /// sentence (`ErrorSentence.with`), so they are no counts. 62: the
    /// phrase of a feed the server refused carried its status as a number
    /// in the middle; it now stands behind the phrase.
    nonisolated static let countsWithOneForm = 62

    /// The keys with a counted number whose value in `language` has no
    /// plural forms.
    nonisolated static func countsWithOneForm(_ values: [CatalogValues.Value], language: String) -> Set<String> {
        let mine = values.filter { $0.catalog == "Localizable" && $0.language == language && $0.key.contains("%lld") }
        return Set(mine.filter { $0.part.isEmpty }.map(\.key))
            .subtracting(mine.filter { !$0.part.isEmpty }.map(\.key))
    }

    @Test("a count of episodes or tracks has its plural forms in English and every translation; the other counts with one form are a measured stock", .needsTheSources)
    func countsCarryTheirForms() throws {
        let values = try CatalogValues.all()
        for language in ["de", "es", "fr", "it"] {
            let oneForm = Self.countsWithOneForm(values, language: language)
            #expect(!oneForm.contains("%lld episodes") && !oneForm.contains("%lld tracks"),
                    "\(language) says every count of episodes or tracks in one form")
            #expect(oneForm.count == Self.countsWithOneForm,
                    "\(language): \(oneForm.count) counts with one form, the stock says \(Self.countsWithOneForm)")
        }
        for key in ["%lld episodes", "%lld tracks"] {
            let forms = Set(values.filter { $0.catalog == "Localizable" && $0.key == key && $0.language == "en" }.map(\.part))
            #expect(forms.isSuperset(of: ["one", "other"]), "English says 1 of \(key)")
        }
        // Calibration: a plain text counts, a text with forms does not.
        let probe = [CatalogValues.Value(catalog: "Localizable", key: "%lld a", language: "de", part: "", text: "%lld A"),
                     CatalogValues.Value(catalog: "Localizable", key: "%lld b", language: "de", part: "one", text: "%lld B"),
                     CatalogValues.Value(catalog: "Localizable", key: "%lld b", language: "de", part: "other", text: "%lld Bs")]
        #expect(Self.countsWithOneForm(probe, language: "de") == ["%lld a"])
    }

    @Test("every text in every language carries the placeholders of its English text, and every Siri phrase the app's name", .needsTheSources)
    func everyLanguageKeepsThePlaceholders() throws {
        let values = try CatalogValues.all()
        #expect(values.contains { $0.language == "de" && $0.catalog == "Localizable" }, "the fence read no German text")
        let english = Dictionary(values.filter { $0.language == "en" }.map { ("\($0.catalog)/\($0.key)#\($0.part)", $0.text) }) { first, _ in first }
        var offenders: [String] = []
        for value in values where value.language != "en" {
            if value.catalog == "AppShortcuts" {
                if !value.text.contains("${applicationName}") { offenders.append("\(value.language) \(value.key): \(value.text)") }
                continue
            }
            let source = english["\(value.catalog)/\(value.key)#\(value.part)"] ?? value.key
            if CatalogValues.placeholders(value.text) != CatalogValues.placeholders(source) {
                offenders.append("\(value.language) \(value.catalog)/\(value.key)#\(value.part): \(value.text)")
            }
        }
        #expect(offenders.isEmpty, "texts whose placeholders differ from English: \(offenders.sorted().prefix(10))")
        // Calibration: kinds count, positions do not, a missing one does.
        #expect(CatalogValues.placeholders("%1$@ of %2$lld") == CatalogValues.placeholders("%lld von %@"))
        #expect(CatalogValues.placeholders("%@ episodes") != CatalogValues.placeholders("Folgen"))
        #expect(CatalogValues.placeholders("Play ${book} in ${applicationName}") == ["${applicationName}", "${book}"])
    }

    @Test("the reader takes plain texts, plural forms and Siri phrases of every language")
    func theReaderTakesEveryForm() {
        let strings: [String: Any] = [
            "%lld Episodes": ["localizations": [
                "it": ["variations": ["plural": ["one": ["stringUnit": ["state": "translated", "value": "%lld puntata"]],
                                                 "other": ["stringUnit": ["state": "needs_review", "value": "%lld puntate"]]]]]]],
            "Up Next": ["localizations": ["es": ["stringUnit": ["state": "translated", "value": "A continuación"]]]],
            "Continue in ${applicationName}": ["localizations": [
                "fr": ["stringSet": ["state": "translated", "values": ["Reprendre dans ${applicationName}"]]]]],
        ]
        let values = CatalogValues.values(catalog: "Probe", strings: strings)
        #expect(Set(values.map { "\($0.language)#\($0.part)" }) == ["it#one", "it#other", "es#", "fr#1"])
    }
}
#endif
