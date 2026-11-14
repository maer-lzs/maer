// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Siri hears the bare app name as the German word for "more", so every
/// intent carries a phrase that names the APP ("in der Maer-App",
/// "von der App Maer", "in the Maer app"), and the Info.plist offers spoken
/// alternatives of the name. Measured on a device (GT 14.09.2026): the
/// unregistered form fell to the generic media intent and opened another
/// app. The phrases are string literals in `AppShortcuts.swift`, so the
/// witness reads the source; the plist is read as a plist.
struct AppShortcutPhrasesTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The phrase blocks of the shortcuts file, one array per intent.
    nonisolated static func phraseBlocks(in source: String) -> [[String]] {
        source.components(separatedBy: "phrases: [").dropFirst().map { tail in
            let block = tail.components(separatedBy: "]").first ?? ""
            return block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("\"") }
        }
    }

    nonisolated static func namesTheApp(_ phrase: String) -> Bool {
        phrase.range(of: "\\bapp\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test("every intent has a phrase that names the app as an app", .needsTheSources)
    func everyIntentHasAPhraseNamingTheApp() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/AppShortcuts.swift"), encoding: .utf8)
        let blocks = Self.phraseBlocks(in: source)
        // Two shortcuts while drive mode's gate is closed (`DriveModeGate`).
        try #require(blocks.count >= 2, "the finder must still find the phrase blocks")
        for (index, block) in blocks.enumerated() {
            #expect(block.contains(where: Self.namesTheApp), "intent \(index) has no phrase with the word app: \(block)")
        }
        // The name is the device's own (`.applicationName`), never spelled
        // out: the app is called Mär, and a written name would miss it.
        let spelled = blocks.flatMap { $0 }.filter { $0.localizedCaseInsensitiveContains("maer") || $0.contains("Mär") }
        #expect(spelled.isEmpty, "a phrase spells the name out: \(spelled)")
        // The forms a person actually said: "von der App Maer" and "in der Maer-App".
        #expect(blocks.flatMap { $0 }.contains { $0.contains("von der App") })
        #expect(blocks.flatMap { $0 }.contains { $0.contains("-App") })
        #expect(Self.namesTheApp("Play \\(\\.$book) in the \\(.applicationName) app"))
        #expect(!Self.namesTheApp("Play \\(\\.$book) in \\(.applicationName)"))
        #expect(!Self.namesTheApp("Höre mein Hörbuch in Maer weiter, appetitlich"), "a word containing app is not the word")
    }

    /// A phrase as the catalog spells it: the literal without its quotes and
    /// comma, the app name and the book parameter as catalog placeholders.
    nonisolated static func catalogForm(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(",") { text.removeLast() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return text.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")
            .replacingOccurrences(of: "\\(\\.$book)", with: "${book}")
            .replacingOccurrences(of: "\\(\\.$routine)", with: "${routine}")
    }

    /// The build files each shortcut's phrases under its first phrase in the
    /// table AppShortcuts; without a catalog of that name they travel with no
    /// German form. The German set holds every phrase of the source, so a
    /// German device hears what it heard before the catalog.
    @Test("the Siri catalog carries per intent its first sentence with all sentences in German", .needsTheSources)
    func theShortcutCatalogCarriesEveryPhraseInGerman() throws {
        #expect(Self.catalogForm(#"                "Play \(\.$book) in the \(.applicationName) app","#)
                == "Play ${book} in the ${applicationName} app")
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/AppShortcuts.swift"), encoding: .utf8)
        let blocks = Self.phraseBlocks(in: source).map { $0.map(Self.catalogForm) }
        try #require(blocks.count >= 2, "the finder must still find the phrase blocks")
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Sources/AppShortcuts.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any], "the catalog has no strings")
        // A stale key is a shortcut the source does not offer now; the
        // archive warns of it. A shortcut that comes back brings its
        // phrases back with it.
        let stale = Set(strings.filter { ($0.value as? [String: Any])?["extractionState"] as? String == "stale" }.keys)
        #expect(stale.isEmpty, "a stale shortcut: \(stale.sorted())")
        #expect(Set(strings.keys) == Set(blocks.compactMap(\.first)), "one key per shortcut, its first phrase: \(strings.keys.sorted())")
        for block in blocks {
            let key = try #require(block.first)
            let entry = strings[key] as? [String: Any]
            let german = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringSet"] as? [String: Any]
            let values = german?["values"] as? [String] ?? []
            #expect(Set(values) == Set(block), "the German phrases of \(key) are not the source's: \(values)")
            #expect(german?["state"] as? String == "translated", "\(key) has no translated German set")
        }
    }

    @Test("the Info.plist names spoken alternatives of the name, EACH WITH its sound", .needsTheInfoPlist)
    func infoPlistOffersAlternativeAppNames() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Maer-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let alternatives = try #require(plist["INAlternativeAppNames"] as? [[String: Any]])
        let names = alternatives.compactMap { $0["INAlternativeAppName"] as? String }
        #expect(names.contains("Maer App") && names.contains("Mär App"), "the two spoken forms: \(names)")

        // The case used to count ONLY the names and was green while not a
        // single one had a pronunciation hint. A fence that checks one
        // half of a construction confirms the other as present. A spelling
        // matters to nobody for a SPOKEN command; the sound is the half
        // that counts.
        for alternative in alternatives {
            let name = (alternative["INAlternativeAppName"] as? String) ?? "(ohne Namen)"
            let hint = alternative["INAlternativeAppNamePronunciationHint"] as? String
            #expect(!(hint ?? "").isEmpty, "die Alternative \(name) traegt keinen Laut")
        }

        // How the SYSTEM speaks the name. An English voice otherwise reads
        // "Mär" as "mar".
        let spoken = plist["CFBundleSpokenName"] as? String
        #expect(!(spoken ?? "").isEmpty, "CFBundleSpokenName fehlt oder ist leer")
    }

    @Test("what is in the catalog arrives in the product: an entry is a KEY or it is invariant", .needsTheSources, .needsTheInfoPlist)
    func everyCatalogEntryEitherIsAKeyOrSaysItIsNotTranslated() throws {
        // `InfoPlist.strings` replaces by the Info.plist KEY. An entry
        // whose name is a VALUE produces a line that replaces nothing: it is
        // in the product and has no effect. That is exactly how three
        // sounds lay here until someone checked the built archive.
        //
        // And the sounds in `INAlternativeAppNames` are NOT REACHABLE AT ALL
        // by this route, because they sit in an array of dictionaries. They
        // are therefore invariant, and that is no carelessness but the
        // only honest marking.
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Maer-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Sources/InfoPlist.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        try #require(!strings.isEmpty, "der Sucher findet die Eintraege noch")

        // Not every effective key is in the FILE: two come from the build
        // settings and land only in the generated Info.plist. The reason
        // is in the entry, so that the exception explains only what it
        // touches. On the first run this case failed on exactly that,
        // on its own too narrow wording.
        let injectedByTheBuild: [String: String] = [
            "CFBundleDisplayName": "kommt aus PRODUCT_DISPLAY_NAME, nicht aus der Datei",
            "CFBundleName": "kommt aus PRODUCT_NAME, nicht aus der Datei",
        ]
        var withoutEffect: [String] = []
        for (name, entry) in strings {
            guard plist[name] == nil, injectedByTheBuild[name] == nil else { continue }
            if entry["shouldTranslate"] as? Bool != false { withoutEffect.append(name) }
        }
        #expect(withoutEffect.isEmpty,
                "diese Eintraege sind keine Info.plist-Schluessel und geben sich trotzdem als uebersetzbar: \(withoutEffect.sorted())")

        // The opposite direction: the spoken name IS a top-level
        // key, so it must be localized, otherwise every voice reads it
        // in the base version.
        let spoken = try #require(strings["CFBundleSpokenName"], "CFBundleSpokenName steht nicht im Katalog")
        let localizations = try #require(spoken["localizations"] as? [String: Any])
        #expect(localizations["de"] != nil && localizations["en"] != nil,
                "der gesprochene Name braucht beide Sprachen, hat: \(localizations.keys.sorted())")
    }

    /// The system's own questions (the sign-in window's question among
    /// them) name the app by its bundle name in the device's language, not
    /// by the display name. The build sets the bundle name from the target
    /// name; the translation in both languages carries „Mär“.
    @Test("the built app carries the name of the bundle in both languages as „Mär“")
    func theBuiltAppNamesItselfMaerInBothLanguages() throws {
        for language in ["de", "en"] {
            let path = try #require(Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil,
                                                     forLocalization: language), "\(language): no InfoPlist.strings")
            let strings = try #require(NSDictionary(contentsOfFile: path) as? [String: String], "\(language): unreadable")
            #expect(strings["CFBundleName"] == "Mär", "\(language): \(String(describing: strings["CFBundleName"]))")
        }
    }
}
#endif
