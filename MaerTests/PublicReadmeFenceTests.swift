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

    /// The names without the owner. The workshop files carry his name in
    /// several hundred places, and whether it belongs there is his decision
    /// and not a rule anyone draws for him. So the wider scope measures the
    /// agent names only, and the two public READMEs keep measuring all of
    /// them, because a stranger reads those.
    static let agentNames = ["Momo", "Pie", "Takt", "fable", "Fable"]

    /// The copyright notice is the one place a person belongs. It is
    /// recognised by its SHAPE, never by an exact phrase: the first version
    /// of this exemption carried the year 2026 and the capital `C`, and the
    /// repository holds a line with a small `c` and one from 2007. An
    /// exemption pinned to a year stops working in January, silently.
    static func isCopyrightNotice(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard lower.contains("copyright") else { return false }
        return jahreszahl(in: line) != nil
    }

    /// A four-digit year, so that the word alone is not enough: a sentence
    /// ABOUT copyright is not a copyright notice.
    static func jahreszahl(in line: String) -> String? {
        var digits = ""
        for character in line {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 { return digits }
            } else {
                digits = ""
            }
        }
        return nil
    }

    /// The AI disclosure names MODELS beside Opus and Sonnet, so `Fable` there
    /// is a product and not a role. It is exempt from its marker to the
    /// closing bracket and **not one character further**: an exemption that
    /// swallowed the whole line would go blind, invisibly, the day that line
    /// carries anything else. The span form also lets the model list change
    /// without the fence turning red for a legitimate edit.
    static let exemptSpans = [(start: "Anthropic Claude", end: ")")]

    /// `Takt` is the one name that is also an ordinary word here: the project
    /// calls a runner's cadence its Takt.
    ///
    /// **The distinction is a CLOSED list of the shapes the thing takes, not
    /// an open list of the shapes the person takes.** A list of person places
    /// would grow with every new text, and it was measured to be incomplete
    /// before it was written: the person also stands bare (`an Takt gemeldet`)
    /// and also in front of a space (`Takt gate`). The thing, by contrast,
    /// takes three shapes in the whole tree and no more.
    static let cadenceDeterminers = [
        "der", "die", "das", "dem", "den", "des", "ein", "eine", "einen", "einem", "eines",
        "kein", "keine", "keinen", "keinem", "sein", "seine", "seinen", "seinem",
        "ihr", "ihre", "ihren", "ihrem", "jeden", "jedem", "im", "vom", "zum", "beim",
    ]

    /// The thing, in the three shapes it really takes:
    /// 1. the head of a hyphen compound (`Nachlade-Takt`, `60-s-Takt`), which
    ///    is the opposite position from the person (`Takt-Gates`);
    /// 2. behind a determiner, with an adjective allowed in between
    ///    (`der Takt`, `kein eigener Takt`, `ihren eigenen Takt`);
    /// 3. a derivation (`Taktung`, `Takte`), which never matches the name
    ///    anyway because a letter follows it.
    static func isCadence(before: Substring, after: Substring) -> Bool {
        if before.last == "-", before.dropLast().last?.isLetter == true { return true }
        let words = before.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .suffix(2)
            .map(String.init)
        for word in words where cadenceDeterminers.contains(word) { return true }
        _ = after
        return false
    }

    /// Every role name that stands alone on this line, with its ending.
    /// `names` picks the scope: the public READMEs measure every role, the
    /// workshop files measure the agents only.
    static func roleNameHits(in line: String, names: [String]? = nil) -> [String] {
        var text = line
        if isCopyrightNotice(line), let start = text.lowercased().range(of: "copyright") {
            // A copyright notice is a formula that owns its line, so the
            // exemption runs from the word to the end of it, and only on a
            // line that really carries the shape.
            let width = text.distance(from: start.lowerBound, to: text.endIndex)
            text.replaceSubrange(start.lowerBound..<text.endIndex,
                                 with: String(repeating: " ", count: width))
        }
        for span in exemptSpans {
            text = blanked(from: span.start, to: span.end, in: text)
        }
        for identifier in allowedIdentifiers {
            text = text.replacingOccurrences(of: identifier,
                                             with: String(repeating: " ", count: identifier.count))
        }
        var hits: [String] = []
        for name in names ?? roleNames {
            for ending in endings {
                let form = name + ending
                for index in standingAlone(form, in: text) {
                    if name == "Takt", ending == "" || ending == "s",
                       isCadence(before: text[text.startIndex..<index],
                                 after: text[text.index(index, offsetBy: form.count)...]) {
                        continue
                    }
                    hits.append(form)
                    break
                }
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
        !standingAlone(form, in: text).isEmpty
    }

    /// Every position where the form stands alone. The positions matter for
    /// `Takt`, where what stands beside the word decides whether it is the
    /// person or the cadence.
    static func standingAlone(_ form: String, in text: String) -> [String.Index] {
        var found: [String.Index] = []
        var search = text[text.startIndex...]
        while let range = search.range(of: form) {
            let beforeOK = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex
                || !text[range.upperBound].isLetter
            if beforeOK && afterOK { found.append(range.lowerBound) }
            search = text[range.upperBound...]
        }
        return found
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

        // Where the narrow scope once checked hard, the cadence now passes.
        // The witness that used to assert the opposite is why this change is
        // a decision and not a surprise: widening the fence tore it, and the
        // distinction had to be built before the tear could go away.
        #expect(Self.roleNameHits(in: "im Takt von 30 Sekunden").isEmpty,
                "die Sache steht hinter einem Begleiter und ist keine Person")

        // The exemption reaches its own find and stops there. Both lines carry
        // the disclosure; only the second carries a role beside it.
        let nurOffenlegung = "Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable), plus local models"
        #expect(Self.roleNameHits(in: nurOffenlegung).isEmpty)
        #expect(!Self.roleNameHits(in: nurOffenlegung + ", gemeldet an Momo").isEmpty,
                "die Ausnahme deckt die Offenlegung, nicht den Rest der Zeile")
        #expect(Self.roleNameHits(in: "Anthropic Claude (Opus, Sonnet und Fable)").isEmpty,
                "auch die deutsche Offenlegung, und der Modellname darin darf wechseln")

        // The copyright notice is recognised by its shape. The first version
        // of this exemption was an exact phrase carrying the year 2026 and a
        // capital C, and the repository holds a line with a small c and one
        // from 2007: it would have gone red in January.
        #expect(Self.isCopyrightNotice("// Copyright (C) 2026 Laurenz Schröder"))
        #expect(Self.isCopyrightNotice("Copyright (c) 2007 Free Software Foundation"))
        #expect(Self.isCopyrightNotice("# copyright 2031 someone else"))
        #expect(!Self.isCopyrightNotice("der Abschnitt ueber Copyright und Lizenz"),
                "ein Satz UEBER das Urheberrecht ist keine Urheberrechtszeile")
        #expect(Self.roleNameHits(in: "Copyright (c) 2031 Momo").isEmpty,
                "die Zeile gehoert der Formel, gleich welches Jahr sie traegt")
    }

    /// The cadence and the person, both directions, on the shapes that really
    /// stand in the tree. The thing list was taken from the stock, not from
    /// imagination: eleven places carry the cadence, and these are their
    /// shapes.
    @Test("das Fachwort steht in drei Gestalten, die Person in keiner davon")
    func theCadenceHasItsOwnShapes() {
        let sache = [
            "Der Nachlade-Takt haengt am selben Tageswechsel",
            "Tick im 60-s-Takt; Phasenwechsel im 5-s-Tick",
            "der Sync-Takt ist 30 s, kuerzeres Hoeren misst nichts",
            "der Takt kommt vom Traeger, nicht aus einer Konstanten",
            "kein eigener Takt, gemessen wird am Wirt",
            "Und der taegliche Takt bleibt davon unberuehrt",
            "waere still auf ihren eigenen Takt gefallen",
            "der Dienst waehlt seinen Takt selbst",
            "im Takt von 1 bis 3 s plus Latenz je Station",
            "die Taktung der Anfragen",
            "Queue-Takt (R32-Frage) beziffert statt veraendert",
        ]
        for zeile in sache {
            #expect(Self.roleNameHits(in: zeile, names: Self.agentNames).isEmpty,
                    "das ist das Fachwort: \(zeile)")
        }

        let personen = [
            "Auftrag `f291df3`, Takts Ballon-41-Fassung uebernommen",
            "Takt-Tore aktiv vorgefuehrt",
            "# Takt-Gates (unveraendert gueltig)",
            "sind Linter-Luecken, an Takt gemeldet",
            "# Takt gate: nothing measured",
            "9/9 endpoints clean (Takt's matrix, wave 3)",
        ]
        for zeile in personen {
            #expect(!Self.roleNameHits(in: zeile, names: Self.agentNames).isEmpty,
                    "das ist die Person: \(zeile)")
        }
    }

    /// The same names one surface further out. **The owner is deliberately
    /// NOT measured here**: his name stands in several hundred workshop
    /// lines, and whether it belongs there is his decision.
    @Test("die Werkstatt-Dateien nennen keinen Agenten mehr", .needsTheSources)
    func theWorkshopFilesNameNoAgent() throws {
        let files = try Self.workshopTexts()
        try #require(files.count > 40, "der Zaun hat die Werkstatt nicht gelesen")
        var offenders: [String] = []
        for (name, text) in files {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for hit in Self.roleNameHits(in: String(line), names: Self.agentNames) {
                    offenders.append("\(name):\(number + 1) \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty, "ein Agent steht in der Werkstatt: \(offenders)")
    }

    /// `docs/`, `tools/`, `scripts/` and `MaerTests/`, without the two fence
    /// files: they carry the name list and the planted probe lines, so a
    /// fence that read them would tear at its own instrument.
    static let fenceFiles = ["ProjectFileIntegrityTests.swift", "PublicReadmeFenceTests.swift"]

    static func workshopTexts() throws -> [(name: String, text: String)] {
        var found: [(String, String)] = []
        for folder in ["docs", "tools", "scripts", "MaerTests"] {
            let directory = SourceTree.root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                guard !fenceFiles.contains(name),
                      ["swift", "py", "sh", "md", "json", "txt"].contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                // The WHOLE path, not folder plus file name: two READMEs in
                // two subfolders would otherwise share a label, and a fence
                // that names the wrong file costs the next reader an hour.
                let path = url.path.replacingOccurrences(of: SourceTree.root.path + "/", with: "")
                found.append((path, text))
            }
        }
        return found
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
