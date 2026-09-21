// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// The two READMEs are the surface a stranger reads first, and until now no
/// fence measured them.
///
/// **Measured, which is why this file exists.** A role name stood in
/// `README.md` and in `README.de.md` and travelled to the public mirror. The
/// neighbouring fence in `ProjectFileIntegrityTests` holds, but it reads
/// `Sources`, `MaerWidgets` and `LiveActivityWidget` and only `.swift`, so it
/// was never asked. A fence that holds where nothing happens says nothing
/// about the place where something did.
///
/// **The scope is deliberately narrow: exactly these two files.** `docs/`,
/// `tools/` and `MaerTests/` carry hundreds of names and are a separate
/// question with a separate decision. Whoever widens this fence reads
/// `takt` below first.
struct PublicReadmeFenceTests {
    /// The role names, and the search is CASE-SENSITIVE on purpose.
    /// `PIES` and `SPIELT` are German words in capitals, `piel` and `piegel`
    /// sit inside several hundred more; a case-blind search would fire on all
    /// of them. The price is that a name shouted in capitals escapes, and that
    /// price is paid knowingly: this surface has none (measured).
    static let roleNames = ["Laurenz", "Momo", "Pie", "Takt", "fable", "Fable"]

    /// Every inflection that really occurs in the tree, not every one that is
    /// imaginable: the plain form, the German genitive `s`, the apostrophe a
    /// name ending in `s` takes instead, and the English possessive, each with
    /// the typewriter and the typographic apostrophe. A hyphen is not in this
    /// list because it is not part of the name: `Laurenz-Entscheid` is caught
    /// by the plain form, since a hyphen is not a letter.
    static let endings = ["", "s", "'", "\u{2019}", "'s", "\u{2019}s"]

    /// Identifiers that CONTAIN a role name and are not a person: the channel
    /// branches and the service accounts. They are blanked before the search
    /// rather than pattern-matched around, because an exception that explains
    /// more than its own find is a hole with a name. None of them stands in
    /// the two files today; they are listed because this surface grows.
    static let allowedIdentifiers = [
        "fable-auftraege", "fable-berichte", "fable-bot",
        "pie-auftraege", "pie-berichte", "pie-bot",
        "momo-bot", "takt-bot", "zul-merge-bot",
    ]

    /// The copyright notice is the one place a person belongs, and it is an
    /// exact phrase: the licence header is fixed in this project, so any
    /// deviation from it should be seen rather than excused.
    static let exemptPhrases = ["Copyright (C) 2026 Laurenz Schröder"]

    /// The AI disclosure names MODELS beside Opus and Sonnet, so `Fable` there
    /// is a product and not a role. It is exempt from its marker to the
    /// closing bracket and **not one character further**: an exemption that
    /// swallowed the whole line would go blind, invisibly, the day that line
    /// carries anything else. The span form also lets the model list change
    /// without the fence turning red for a legitimate edit.
    static let exemptSpans = [(start: "Anthropic Claude", end: ")")]

    /// The one sharpness of the narrow scope, written down so a later widening
    /// cannot inherit it unnoticed: `Takt` is also the German word for a
    /// cadence, and the project uses it that way (`Nachlade-Takt`, `Taktung`).
    /// Neither README says it today, so the check is hard here. On any surface
    /// that talks about cadence this fence would be wrong, and that is a
    /// decision to take openly, not a detail to discover.
    static let hardWordWithAnotherMeaning = "Takt"

    /// Every role name that stands alone on this line, with its ending.
    static func roleNameHits(in line: String) -> [String] {
        var text = line
        for phrase in exemptPhrases {
            text = text.replacingOccurrences(of: phrase,
                                             with: String(repeating: " ", count: phrase.count))
        }
        for span in exemptSpans {
            text = blanked(from: span.start, to: span.end, in: text)
        }
        for identifier in allowedIdentifiers {
            text = text.replacingOccurrences(of: identifier,
                                             with: String(repeating: " ", count: identifier.count))
        }
        var hits: [String] = []
        for name in roleNames {
            for ending in endings where standsAlone(name + ending, in: text) {
                hits.append(name + ending)
            }
        }
        return hits
    }

    /// Blanks every span from `start` up to and including the first `end`
    /// behind it. Without an `end` the span reaches the end of the line: an
    /// unclosed bracket means the disclosure runs to the margin, and guessing
    /// the other way would leave a name measured that the exemption covers.
    static func blanked(from start: String, to end: String, in text: String) -> String {
        var result = text
        while let opening = result.range(of: start) {
            let tail = result[opening.upperBound...]
            let closing = tail.range(of: end)?.upperBound ?? result.endIndex
            let width = result.distance(from: opening.lowerBound, to: closing)
            result.replaceSubrange(opening.lowerBound..<closing,
                                   with: String(repeating: " ", count: width))
        }
        return result
    }

    /// One statement is a bullet plus the lines that continue it. Markdown
    /// wraps a sentence over several lines, and a fence that read single lines
    /// would tear at a line break instead of at the claim.
    static func statements(in text: String) -> [String] {
        var out: [String] = [""]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("- ") {
                out.append(String(line))
            } else {
                out[out.count - 1] += " " + String(line)
            }
        }
        return out
    }

    /// A form counts only where no LETTER touches it on either side. A hyphen,
    /// a slash and an apostrophe are not letters, so `Laurenz-Entscheid` is a
    /// hit while `Piece` and `Beispiel` are not.
    static func standsAlone(_ form: String, in text: String) -> Bool {
        var search = text[text.startIndex...]
        while let range = search.range(of: form) {
            let beforeOK = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex
                || !text[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            search = text[range.upperBound...]
        }
        return false
    }

    static func readmeTexts() throws -> [(name: String, text: String)] {
        try ["README.md", "README.de.md"].map { name in
            (name, try String(contentsOf: SourceTree.root.appendingPathComponent(name),
                              encoding: .utf8))
        }
    }

    @Test("die zwei oeffentlichen READMEs nennen keine Rolle", .needsTheSources)
    func theTwoPublicReadmesNameNoRole() throws {
        let files = try Self.readmeTexts()
        for (name, text) in files {
            // The precondition names what the fence must see, never a number
            // that happens to fit today.
            try #require(text.contains("## License") || text.contains("## Lizenz"),
                         "\(name) ist nicht die Leseflaeche, der Zaun misst nichts")
        }
        var offenders: [String] = []
        for (name, text) in files {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for hit in Self.roleNameHits(in: String(line)) {
                    offenders.append("\(name):\(number + 1) \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "eine Rolle steht auf der Flaeche, die ein Fremder zuerst liest: \(offenders)")
    }

    /// The instrument itself, in both directions. Every line here was measured
    /// in the tree before it was written down; a form nobody writes would make
    /// the fence look stronger than it is.
    @Test("der Leseflaechen-Zaun faengt jede Beugung und keine Kollision")
    func theReadmeFenceCatchesEveryFormAndNoCollision() {
        let muessenReissen = [
            "- 9/9 Subsonic endpoints clean (Takt's matrix, wave 3)",
            "- 9/9 Subsonic-Endpunkte sauber (Takts Matrix, Welle 3)",
            "auf Laurenz' Wort vom 22.09.",
            "ENTSCHEID Laurenz, und er bindet",
            "ein Laurenz-Entscheid aus dem Kanal",
            "Momos Messung sagt etwas anderes",
            "das Momo-GO liegt vor",
            "Pies Regelkarte, Zeile 1",
            "fables Zaun misst die Gestalt",
            "Takt\u{2019}s matrix, typografisch",
            "Laurenz\u{2019} Wort, typografisch",
            "Momo's own probe says so",
            "Anthropic Claude (Opus, Sonnet and Fable)"
                .replacingOccurrences(of: "Anthropic Claude", with: "die Modelle"),
        ]
        for zeile in muessenReissen {
            #expect(!Self.roleNameHits(in: zeile).isEmpty, "diese Form entkommt: \(zeile)")
        }

        let duerfenNichtReissen = [
            "ein Beispiel, das nichts beweist",
            "der Spiegel der Ablage",
            "die Datei wird kopiert",
            "eine Kopie neben dem Original",
            "one Piece of the answer",
            "SPIELT die naechste Folge ab",
            "die PIES-Reihe im Katalog",
            "git.lschroeder.eu/laurenz/maer-sync",
            "die Berichte liegen auf fable-berichte",
            "der Zugang heisst momo-bot",
            "// Copyright (C) 2026 Laurenz Schröder",
            "Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable)",
        ]
        for zeile in duerfenNichtReissen {
            #expect(Self.roleNameHits(in: zeile).isEmpty,
                    "das ist keine Person: \(zeile) -> \(Self.roleNameHits(in: zeile))")
        }

        // The sharpness of the narrow scope, asserted so that it is a decision
        // and not a surprise: here the cadence tears too.
        #expect(!Self.roleNameHits(in: "im Takt von 30 Sekunden").isEmpty,
                "in diesem engen Bereich wird hart geprueft, und das gehoert gemessen")

        // The exemption reaches its own find and stops there. Both lines carry
        // the disclosure; only the second carries a role beside it.
        let nurOffenlegung = "Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable), plus local models"
        #expect(Self.roleNameHits(in: nurOffenlegung).isEmpty)
        #expect(!Self.roleNameHits(in: nurOffenlegung + ", gemeldet an Momo").isEmpty,
                "die Ausnahme deckt die Offenlegung, nicht den Rest der Zeile")
        #expect(Self.roleNameHits(in: "Anthropic Claude (Opus, Sonnet und Fable)").isEmpty,
                "auch die deutsche Offenlegung, und der Modellname darin darf wechseln")
    }

    /// The other half of the same repair: the claim about the service is
    /// measured in both languages, because the wrong sentence has a German
    /// spelling too.
    @Test("die Dienst-Aussage wird als Aussage gemessen, nicht als englische Schreibweise")
    func theServiceClaimIsMeasuredAsAClaim() {
        let deutscherRueckfall = """
        - **Ein eigener Sync-Dienst.** Unter Einstellungen, Sync (eigenes Repository,
          Standardbibliothek Python, eine SQLite-Datei). Beim Anmelden wird getauscht.
        """
        let ohneRust = Self.statements(in: deutscherRueckfall)
            .filter { $0.contains("Python") && !$0.contains("Rust") }
        #expect(ohneRust.count == 1, "der deutsche Rueckfall muss auffallen")

        let heutigeForm = """
        - Der Dienst (eine SQLite-Datei; ausgeliefert wird die Rust-Fassung,
          die Python-Fassung bleibt als Rueckweg daneben liegen).
        """
        let stillOK = Self.statements(in: heutigeForm)
            .filter { $0.contains("Python") && !$0.contains("Rust") }
        #expect(stillOK.isEmpty, "ueber den Zeilenumbruch hinweg ist es EINE Aussage")
    }

    /// What the app says about the service must not outlive the service. The
    /// deployed build has been the Rust one since `v0.2.0`; a reader who
    /// follows the old sentence builds the way nobody runs.
    /// **The first version of this witness searched `standard-library
    /// Python`, an ENGLISH spelling.** That string cannot stand in the German
    /// file at all, where the same wrong sentence would read
    /// `Standardbibliothek Python`, so half the surface was unmeasured while
    /// the fence looked green. What is measured now is the CLAIM: wherever
    /// the service's language is named, the build that runs is named with it.
    @Test("beide Leseflaechen nennen die ausgelieferte Fassung des Dienstes", .needsTheSources)
    func bothSurfacesNameTheDeployedBuild() throws {
        for (name, text) in try Self.readmeTexts() {
            #expect(text.contains("Rust"), "\(name) sagt nicht, was ausgeliefert wird")
            for statement in Self.statements(in: text) where statement.contains("Python") {
                #expect(statement.contains("Rust"),
                        "\(name) nennt Python ohne die Fassung, die laeuft: \(statement.prefix(80))")
            }
        }
    }

    /// Parity of the two surfaces. The German one may be shorter, but it may
    /// not be silent: it went five months without knowing the service existed,
    /// including in the section about where data travels.
    @Test("die deutsche Leseflaeche kennt den Dienst, auch im Datenschutz-Abschnitt", .needsTheSources)
    func theGermanSurfaceKnowsTheService() throws {
        let files = try Self.readmeTexts()
        for (name, text) in files {
            #expect(text.contains("maer-sync"), "\(name) nennt den Dienst nicht")
        }
        let deutsch = try #require(files.first(where: { $0.name == "README.de.md" })?.text)
        let abschnitt = try #require(deutsch.range(of: "## Privatsphäre"))
        let rest = deutsch[abschnitt.upperBound...]
        let ende = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        #expect(rest[..<ende].contains("Sync-Dienst"),
                "der deutsche Datenschutz-Abschnitt schweigt ueber den eigenen Dienst")
    }

    /// One thought, one sentence, on the surface too. The stock is zero in
    /// both files and may only stay there.
    @Test("die zwei READMEs tragen keinen Gedankenstrich", .needsTheSources)
    func theTwoReadmesCarryNoDash() throws {
        for (name, text) in try Self.readmeTexts() {
            let strich = text.filter { $0 == "\u{2014}" || $0 == "\u{2013}" }.count
            #expect(strich == 0, "\(name) traegt \(strich) Gedankenstriche")
        }
    }
}
#endif
