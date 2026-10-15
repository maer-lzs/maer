// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Siri hears the bare app name as the German word for "more", so every
/// intent carries a phrase that names the APP ("in der Maer-App", "von der
/// App Maer", "in the Maer app"), and the Info.plist offers spoken
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

    @Test("jede Absicht hat eine Phrase, die die App als App nennt", .needsTheSources)
    func everyIntentHasAPhraseNamingTheApp() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/AppShortcuts.swift"), encoding: .utf8)
        let blocks = Self.phraseBlocks(in: source)
        try #require(blocks.count >= 3, "the finder must still find the phrase blocks")
        for (index, block) in blocks.enumerated() {
            #expect(block.contains(where: Self.namesTheApp), "intent \(index) has no phrase with the word app: \(block)")
        }
        // The forms a person actually said: "von der App Maer" and "in der Maer-App".
        #expect(blocks.flatMap { $0 }.contains { $0.contains("von der App") })
        #expect(blocks.flatMap { $0 }.contains { $0.contains("-App") })
        #expect(Self.namesTheApp("Play \\(\\.$book) in the \\(.applicationName) app"))
        #expect(!Self.namesTheApp("Play \\(\\.$book) in \\(.applicationName)"))
        #expect(!Self.namesTheApp("Höre mein Hörbuch in Maer weiter, appetitlich"), "a word containing app is not the word")
    }

    @Test("die Info.plist nennt gesprochene Alternativen des Namens, JE MIT ihrem Laut")
    func infoPlistOffersAlternativeAppNames() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Maer-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let alternatives = try #require(plist["INAlternativeAppNames"] as? [[String: Any]])
        let names = alternatives.compactMap { $0["INAlternativeAppName"] as? String }
        #expect(names.contains("Maer App") && names.contains("Mär App"), "the two spoken forms: \(names)")

        // Der Fall zaehlte bisher NUR die Namen und war gruen, waehrend kein
        // einziger einen Aussprache-Hinweis hatte. Ein Zaun, der die eine
        // Haelfte einer Konstruktion prueft, bestaetigt die andere als
        // vorhanden. Eine Schreibweise interessiert bei einem GESPROCHENEN
        // Befehl niemanden; der Laut ist die Haelfte, auf die es ankommt.
        for alternative in alternatives {
            let name = (alternative["INAlternativeAppName"] as? String) ?? "(ohne Namen)"
            let hint = alternative["INAlternativeAppNamePronunciationHint"] as? String
            #expect(!(hint ?? "").isEmpty, "die Alternative \(name) traegt keinen Laut")
        }

        // Wie das SYSTEM den Namen spricht. Eine englische Stimme liest
        // "Mär" sonst als "mar".
        let spoken = plist["CFBundleSpokenName"] as? String
        #expect(!(spoken ?? "").isEmpty, "CFBundleSpokenName fehlt oder ist leer")
    }

    @Test("was im Katalog steht, kommt im Erzeugnis an: ein Eintrag ist ein SCHLUESSEL oder er ist invariant", .needsTheSources)
    func everyCatalogEntryEitherIsAKeyOrSaysItIsNotTranslated() throws {
        // `InfoPlist.strings` ersetzt anhand des Info.plist-SCHLUESSELS. Ein
        // Eintrag, dessen Name ein WERT ist, erzeugt eine Zeile, die nichts
        // ersetzt: sie steht im Erzeugnis und wirkt nicht. Genau so lagen
        // drei Laute hier, bis es jemand am gebauten Archiv nachgesehen hat.
        //
        // Und die Laute in `INAlternativeAppNames` sind ueber diesen Weg
        // UEBERHAUPT nicht erreichbar, weil sie in einem Array von
        // Woerterbuechern stehen. Sie sind deshalb invariant, und das ist
        // keine Nachlaessigkeit, sondern die einzige ehrliche Kennzeichnung.
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Maer-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Sources/InfoPlist.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        try #require(!strings.isEmpty, "der Sucher findet die Eintraege noch")

        // Nicht jeder wirksame Schluessel steht in der DATEI: zwei kommen
        // aus den Bau-Einstellungen und landen erst im erzeugten Info.plist.
        // Der Grund steht im Eintrag, damit die Ausnahme nur erklaert, was
        // sie anfasst. Beim ersten Lauf hat dieser Fall genau daran
        // gerissen, also an seiner eigenen zu engen Fassung.
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

        // Die Gegenrichtung: der gesprochene Name IST ein oberster
        // Schluessel, also gehoert er lokalisiert, sonst liest ihn jede
        // Stimme in der Grundfassung.
        let spoken = try #require(strings["CFBundleSpokenName"], "CFBundleSpokenName steht nicht im Katalog")
        let localizations = try #require(spoken["localizations"] as? [String: Any])
        #expect(localizations["de"] != nil && localizations["en"] != nil,
                "der gesprochene Name braucht beide Sprachen, hat: \(localizations.keys.sorted())")
    }
}
#endif
