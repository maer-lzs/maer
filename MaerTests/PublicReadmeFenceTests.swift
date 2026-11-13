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
/// The READMEs are measured for every role, the workshop files (`docs/`,
/// `tools/`, `scripts/`, `MaerTests/`) further down with their own test.
/// Whoever touches the names reads `Takt` below first.
struct PublicReadmeFenceTests {
    /// The role names. Each is searched in exactly two spellings: as written
    /// here and in capitals. **Not case-blind:** `pie` and `takt` are ordinary
    /// words in lower case, and `piel` and `piegel` sit inside several hundred
    /// more. **Capitals are a spelling of the name:** the fence once searched
    /// only the form below, and `MOMOS INVARIANTE` stood in the inventory,
    /// green, until someone else counted.
    static let roleNames = ["Laurenz", "Momo", "Pie", "Takt", "Wache", "fable", "Fable"]

    /// Words the open count `name\w*` finds in any case that are not a name:
    /// the English noun and the German plural and derivation of the cadence.
    /// An exception holds wherever its word stands, so a word of our own
    /// making is renamed instead of listed here.
    /// Every entry must still stand in the scope, or it is a ghost.
    static let ordinaryWords = ["piece", "pieces", "Takte", "Taktung"]

    /// Every inflection that really occurs in the tree, not every one that is
    /// imaginable: the plain form, the German genitive `s`, the apostrophe a
    /// name ending in `s` takes instead, and the English possessive, each with
    /// the typewriter and the typographic apostrophe. A hyphen is not in this
    /// list because it is not part of the name: `Laurenz-Entscheid` is caught
    /// by the plain form, since a hyphen is not a letter.
    static let endings = ["", "s", "'", "\u{2019}", "'s", "\u{2019}s"]

    /// The endings of the channel branches and service accounts: a name in
    /// lower case followed by one of these is an identifier that names a
    /// role, and the rewritten history carries none of them.
    static let channelSuffixes = ["-bot", "-auftraege", "-berichte"]

    /// The agent names alone. They stay a separate list although every scope
    /// now measures all of them, because the distinction is what the witness
    /// for the cadence needs: it asks about `Takt` without dragging the
    /// owner's name into a sample line.
    static let agentNames = ["Momo", "Pie", "Takt", "Wache", "fable", "Fable"]

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
        isThing(before: before, determiners: cadenceDeterminers)
    }

    /// `Wache` is the role that reviews every commit and, in the code, the
    /// ordinary word for a guard. The guard takes the same closed shapes as
    /// the cadence: the tail of a compound (`Echo-Wache`, `Quellen-Wache`)
    /// or a noun behind a determiner, here also the demonstratives the text
    /// uses (`an dieser Wache`, `dieselbe Wache`). The role stands bare or as
    /// the head of a compound (`Wache-Paket`) and is named after its finding
    /// instead.
    static let guardDeterminers = cadenceDeterminers + [
        "diese", "dieser", "diesem", "dieses", "dieselbe", "derselben", "denselben",
    ]

    static func isGuard(before: Substring, after: Substring) -> Bool {
        isThing(before: before, determiners: guardDeterminers)
    }

    private static func isThing(before: Substring, determiners: [String]) -> Bool {
        if before.last == "-", before.dropLast().last?.isLetter == true { return true }
        let words = before.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .suffix(2)
            .map(String.init)
        for word in words where determiners.contains(word) { return true }
        return false
    }

    /// Every role name that stands alone on this line, with its ending.
    /// `names` picks the scope: the public READMEs measure every role, the
    /// workshop files measure the agents only.
    static func roleNameHits(in line: String, names: [String]? = nil) -> [String] {
        // Every form searched below contains its name in some case: the
        // endings, the capitals, the channel identifiers and the tail behind
        // a copyright notice. A line that holds none of the names in any case
        // has no hit, and almost every line of the sources is such a line.
        let lowered = line.lowercased()
        guard (names ?? roleNames).contains(where: { lowered.contains($0.lowercased()) }) else { return [] }
        var text = line
        var hits: [String] = []
        if isCopyrightNotice(line), let start = text.lowercased().range(of: "copyright") {
            // A copyright notice is a formula that names the owner, so the
            // owner is exempt from the word to the end of the line, and only
            // on a line that really carries the shape. The agents are not:
            // the formula has no place for them, so an agent behind it is
            // still a hit. The word itself is left out of what is searched,
            // or the tail would be read as a formula again.
            let scope = (names ?? roleNames).filter { agentNames.contains($0) }
            hits += roleNameHits(in: String(text[start.upperBound...]), names: scope)
            let width = text.distance(from: start.lowerBound, to: text.endIndex)
            text.replaceSubrange(start.lowerBound..<text.endIndex,
                                 with: String(repeating: " ", count: width))
        }
        for span in exemptSpans {
            text = blanked(from: span.start, to: span.end, in: text)
        }
        // Channel branches and service accounts spell the name in lower
        // case, where two of the names are ordinary words and cannot be
        // searched alone. Their shape is closed, so the shape is searched.
        for name in names ?? roleNames {
            for suffix in channelSuffixes {
                let identifier = name.lowercased() + suffix
                if !hits.contains(identifier), standsAlone(identifier, in: text) {
                    hits.append(identifier)
                }
            }
        }
        var measured = Set<String>()
        for name in names ?? roleNames {
            // The listed spelling and the one in capitals. `fable` and
            // `Fable` share their capitals, so each form is measured once.
            for ending in endings {
                for form in [name + ending, (name + ending).uppercased()]
                where measured.insert(form).inserted {
                    for index in standingAlone(form, in: text) {
                        if name == "Takt", ending == "" || ending == "s",
                           isCadence(before: text[text.startIndex..<index],
                                     after: text[text.index(index, offsetBy: form.count)...]) {
                            continue
                        }
                        if name == "Wache", ending == "",
                           isGuard(before: text[text.startIndex..<index],
                                   after: text[text.index(index, offsetBy: form.count)...]) {
                            continue
                        }
                        hits.append(form)
                        break
                    }
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
            // Channel branches and service accounts carry a name, and the
            // history was rewritten to take them out; a hyphen is not a
            // letter, so the name in them stands alone.
            "die Berichte liegen auf fable-berichte",
            "der Zugang heisst momo-bot",
            // The formula names the owner and nobody else.
            "// Copyright (C) 2026 Laurenz Schröder, gemessen von Momo",
            // The line that stood green in the inventory while the fence
            // searched one spelling only.
            "**MOMOS INVARIANTE ERFUELLT** fuer beide Quellen",
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
            "weiterhin ueber die KOPIE.",
            // The class stays measured although the repository no longer
            // carries such an address: an account name in a URL path is
            // lower case, and lower case is not the name.
            "git.example.test/laurenz/maer-sync",
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
        #expect(Self.roleNameHits(in: "Copyright (c) 2031 Laurenz").isEmpty,
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

    /// The guard in the code and the reviewing role share a word; the code's
    /// guard takes the closed shapes, the role is everything else. The lines
    /// are the shapes the tree really carries.
    @Test("die Wache im Code steht in ihren Gestalten, die Rolle in keiner davon")
    func theGuardHasItsOwnShapes() {
        let sache = [
            "/// Die Wache kostete mehr als das, was sie bewachte.",
            "und die Wache dahinter kehrte still zurueck",
            "kein Griff an eine Wache",
            "ein zweites `@Published` an dieser Wache",
            "die Zeitgrenze ist nur noch die grobe Wache",
            "dieselbe Wache wie im Dienst-Traeger",
            "die Echo-Wache haelt die Stempel",
            "die Quellen-Wache liest einzelne Dateien",
            "Die WACHE gegen Fremdbilder.",
            "Ohne diese Wache holt sie Fremdbilder",
        ]
        for zeile in sache {
            #expect(Self.roleNameHits(in: zeile, names: Self.agentNames).isEmpty,
                    "das ist die Wache im Code: \(zeile)")
        }
        let rolle = [
            "(Wache-Paket W1: die angefangene Musik)",
            "(Auftrag `fae9a66`, Wache #162)",
            "nie x Std. 0 Min. (Wache W-8a-1)",
            "**Wache-Fixtures** liegen bei den Zeugen",
            "Wache hat gemeldet",
        ]
        for zeile in rolle {
            #expect(!Self.roleNameHits(in: zeile, names: Self.agentNames).isEmpty,
                    "das ist die Rolle: \(zeile)")
        }
    }

    /// The same names one surface further out, **the owner's among them**.
    /// His name stays where it is a legal statement, the copyright notice and
    /// the licence text, and falls everywhere it was a signature. What the
    /// notice keeps is recognised by shape, not by a year: the exemption that
    /// carried `2026` would have stopped working in January, silently, with
    /// seven hundred allowed lines hanging on it.
    @Test("die Werkstatt-Dateien nennen keine Rolle mehr", .needsTheSources)
    func theWorkshopFilesNameNoRole() throws {
        let files = try Self.workshopTexts()
        try #require(files.count > 40, "der Zaun hat die Werkstatt nicht gelesen")
        var offenders: [String] = []
        for (name, text) in files {
            // The licence text must name the licensor: that is a legal
            // statement and not a signature, so the OWNER is allowed there
            // and the agents still are not. The exception is this narrow on
            // purpose, one name in one file.
            let scope = Self.licenceDocuments.contains(name) ? Self.agentNames : Self.roleNames
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for hit in Self.roleNameHits(in: String(line), names: scope) {
                    offenders.append("\(name):\(number + 1) \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty, "eine Rolle steht in der Werkstatt: \(offenders)")
    }

    /// Every word an open count finds, `name\w*` in any case: the name
    /// followed by whatever letters, digits or underscores it runs into.
    static func openCountWords(in text: String) throws -> [String] {
        let pattern = "\\b(?:" + roleNames.joined(separator: "|") + ")\\w*"
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// The fence and a case-blind count must not disagree silently. Every word
    /// the open count finds is either a form the fence searches, or it is
    /// named as an ordinary word. A spelling the fence does not know turns
    /// this red before it can stand green somewhere else.
    @Test("die offene Zaehlung findet nichts, was der Zaun nicht kennt", .needsTheSources)
    func theOpenCountFindsNothingTheFenceDoesNotKnow() throws {
        #expect(try Self.openCountWords(in: "MOMOS INVARIANTE, one piece, die Taktung")
                == ["MOMOS", "piece", "Taktung"])

        // The sources are read by the reader of their own fence, so both
        // fences and this count see the same files.
        let sources = ProjectFileIntegrityTests.sourceTexts()
        let files = try Self.readmeTexts() + Self.workshopTexts() + sources
        try #require(files.contains { $0.name == "docs/components.md" },
                     "die Zaehlung hat das Inventar nicht gelesen")
        try #require(sources.contains { $0.name == "PodcastSubscriptions.swift" },
                     "die Zaehlung hat die Quellen nicht gelesen")
        // The fence itself answers which words it searches: asked about the
        // bare word, it reports a hit. A list kept here would agree with the
        // fence only as long as nobody changed the fence.
        var unknown: [String] = []
        var ordinarySeen = Set<String>()
        for (name, text) in files {
            for word in try Self.openCountWords(in: text) where Self.roleNameHits(in: word).isEmpty {
                if Self.ordinaryWords.contains(word) {
                    ordinarySeen.insert(word)
                } else {
                    unknown.append("\(name) \(word)")
                }
            }
        }
        #expect(unknown.isEmpty, "diese Schreibweise kennt der Zaun nicht: \(unknown)")
        #expect(ordinarySeen == Set(Self.ordinaryWords),
                "ein gewoehnliches Wort steht nicht mehr im Baum: \(Set(Self.ordinaryWords).subtracting(ordinarySeen))")
    }

    /// `docs/`, `tools/`, `scripts/` and `MaerTests/`, without the two fence
    /// files: they carry the name list and the planted probe lines, so a
    /// fence that read them would tear at its own instrument.
    static let fenceFiles = ["ProjectFileIntegrityTests.swift", "PublicReadmeFenceTests.swift"]

    /// Documents where the owner must be named because the law says so: the
    /// end user licence names its licensor under its own heading.
    static let licenceDocuments = ["docs/EULA.md"]

    static func workshopTexts() throws -> [(name: String, text: String)] {
        var found: [(String, String)] = []
        for folder in ["docs", "tools", "scripts", "MaerTests"] {
            let directory = SourceTree.root.appendingPathComponent(folder)
            for url in SourceTree.files(under: directory) {
                let name = url.lastPathComponent
                guard !fenceFiles.contains(name),
                      // Measured, not assumed: these are every extension in
                      // those folders that carries prose of ours. What stays
                      // out is foreign test data (`opml`, `xml`, `db`), and
                      // two of those files are not even UTF-8.
                      ["swift", "py", "sh", "md", "json", "txt", "plist", "html"]
                          .contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                found.append((SourceTree.relativePath(of: url), text))
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

    /// The carriers, held against each other rather than the whole sentence.
    ///
    /// **Measured at the code, not at the neighbouring text**: the choices,
    /// the playlists, the statistics and the listening positions run on
    /// CloudKit with the key-value store behind them
    /// (`ChoiceCarrier.swift:60`, `PlaylistCarrier.swift:54`,
    /// `StatsCarrier.swift:57`, `StandCarrier.swift:85`), and the playback
    /// claim has only the key-value store (`ClaimCarrier.swift:47`). The
    /// German half described the fallback as the way for five months, so
    /// what this witness holds is that BOTH halves name BOTH carriers.
    static let carrierTerms = [(englisch: "CloudKit", deutsch: "CloudKit"),
                               (englisch: "key-value store", deutsch: "Schlüsselwert-Speicher")]

    /// The text of one section, from its heading to the next one.
    static func section(startingWith heading: String, in text: String) -> String? {
        guard let start = text.range(of: heading) else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("beide Datenschutz-Abschnitte nennen beide Traeger", .needsTheSources)
    func bothPrivacySectionsNameBothCarriers() throws {
        let files = try Self.readmeTexts()
        let englisch = try #require(Self.section(startingWith: "## Privacy",
                                                 in: files.first(where: { $0.name == "README.md" })?.text ?? ""))
        let deutsch = try #require(Self.section(startingWith: "## Privatsphäre",
                                                in: files.first(where: { $0.name == "README.de.md" })?.text ?? ""))
        for paar in Self.carrierTerms {
            #expect(englisch.contains(paar.englisch),
                    "der englische Abschnitt nennt \(paar.englisch) nicht")
            #expect(deutsch.contains(paar.deutsch),
                    "der deutsche Abschnitt nennt \(paar.deutsch) nicht")
        }
    }

    /// Both surfaces point at the same repository, and at one a stranger can
    /// reach. The old address answered only inside the owner's mesh, so every
    /// link on the public mirror was dead for everybody else.
    @Test("beide Leseflaechen nennen dieselbe, erreichbare Adresse", .needsTheSources)
    func bothSurfacesPointAtTheSameAddress() throws {
        for (name, text) in try Self.readmeTexts() {
            #expect(!text.contains("git.lschroeder.eu"),
                    "\(name) zeigt auf einen Wirt, den ein Fremder nicht erreicht")
            #expect(text.contains("https://github.com/maer-lzs/maer-sync"),
                    "\(name) nennt das Dienst-Repository nicht unter seiner oeffentlichen Adresse")
            #expect(text.contains("https://github.com/maer-lzs/maer>") && text.contains("https://www.reddit.com/r/maer_fm/"),
                    "\(name) nennt die Quelle oder die Gemeinschaft nicht im Kopf")
        }
    }

    /// The public source lies on GitHub; the old host appears only in the
    /// history of the changelog.
    @Test("keine Adresse des frueheren Wirts in der App, den READMEs und docs", .needsTheSources)
    func noAddressOfTheFormerHost() throws {
        var texts = try Self.readmeTexts()
        for folder in ["Sources", "docs"] {
            for file in SourceTree.files(under: SourceTree.root.appendingPathComponent(folder))
            where ["swift", "md", "xcstrings", "plist", "html"].contains(file.pathExtension) {
                texts.append((SourceTree.relativePath(of: file), try String(contentsOf: file, encoding: .utf8)))
            }
        }
        #expect(texts.count > 10, "the precondition: the fence read the files")
        let found = texts.filter { $0.1.contains("codeberg.org/LzS") }.map(\.0)
        #expect(found.isEmpty, "these name the former host: \(found)")
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
