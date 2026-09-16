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

    @Test("jede Absicht hat eine Phrase, die die App als App nennt")
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

    @Test("die Laute werden UEBERSETZT, die Namen nicht")
    func hintsAreTranslatedAndNamesAreNot() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Sources/InfoPlist.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])

        // Ein Eigenname ist sprachinvariant: "Mär App" heisst in jeder
        // Sprache so. Das ist richtig und bleibt.
        for name in ["Maer", "Maer App", "Mär App"] {
            let entry = try #require(strings[name], "der Name \(name) fehlt im Katalog")
            #expect(entry["shouldTranslate"] as? Bool == false, "der Name \(name) soll invariant bleiben")
        }

        // Ein Aussprache-Hinweis ist KEINE Schreibweise, sondern eine
        // Lautumschrift in der Sprache des Sprechenden: Apples eigenes
        // Beispiel schreibt "you nee corn pay" fuer "Unicorn Pay". Die
        // deutsche Umschrift von "Mär" ist ein anderer Text als die
        // englische. Waeren die Hints ebenfalls invariant, waere die zweite
        // Haelfte nach der Regel der ersten gebaut, und dort gilt sie nicht.
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Maer-Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let alternatives = try #require(plist["INAlternativeAppNames"] as? [[String: Any]])
        var hints = Set(alternatives.compactMap { $0["INAlternativeAppNamePronunciationHint"] as? String })
        if let spoken = plist["CFBundleSpokenName"] as? String { hints.insert(spoken) }
        try #require(!hints.isEmpty, "der Sucher findet die Laute noch")

        for hint in hints.sorted() {
            let entry = try #require(strings[hint], "der Laut \(hint) steht nicht im Katalog")
            #expect(entry["shouldTranslate"] as? Bool != false, "der Laut \(hint) darf nicht invariant sein")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations["de"] != nil && localizations["en"] != nil,
                    "der Laut \(hint) braucht beide Sprachen, hat: \(localizations.keys.sorted())")
        }
    }
}
#endif
