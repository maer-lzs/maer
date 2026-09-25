// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Wiederherstellungs-Schluessel der reisenden Feed-Zugaenge: seine
/// SCHRIFTFORM (pur) und die eine Zusage, an der der ganze Punkt haengt,
/// naemlich dass er nicht ueber Apple reist.
struct DeviceLinkCodeTests {

    // MARK: - Die Schriftform

    /// Ein Code, den die Tests von Hand schreiben. Nur Buchstaben aus dem
    /// Alphabet, genau so lang wie verlangt.
    static let sample = "ABCDEFGHJKMNPQRSTVWXYZAB"
    static let other  = "ZYXWVTSRQPNMKJHGFEDCBAZY"

    @Test("vierundzwanzig Zeichen werden sechs Gruppen, alles andere bleibt wie es ist")
    func groupingIsSixBlocksOrNothing() {
        let code = Self.sample
        #expect(code.count == DeviceLinkCode.length)
        #expect(DeviceLinkCode.grouped(code) == "ABCD-EFGH-JKMN-PQRS-TVWX-YZAB")
        // Eine falsche Laenge bekommt KEINE vertraute Gestalt: sonst sieht
        // ein kaputter Wert aus wie ein richtiger.
        #expect(DeviceLinkCode.grouped("ABCD") == "ABCD")
        #expect(DeviceLinkCode.grouped("") == "")
    }

    @Test("gelesen wird, was ein Mensch tippt: Striche, Leerzeichen, Kleinschrift")
    func readingAcceptsWhatPeopleType() {
        let want = Self.sample
        #expect(DeviceLinkCode.normalized("ABCD-EFGH-JKMN-PQRS-TVWX-YZAB") == want)
        #expect(DeviceLinkCode.normalized("abcd efgh jkmn pqrs tvwx yzab") == want)
        #expect(DeviceLinkCode.normalized("abcdefghjkmnpqrstvwxyzab") == want)
    }

    @Test("die verwechselbaren Zeichen gibt es gar nicht erst, und nichts wird still berichtigt")
    func theConfusableShapesSimplyDoNotOccur() {
        // Ohne Ziffern im Alphabet kann die Verwechslung nicht entstehen:
        // niemand sieht hier eine 1 und tippt ein I dafuer. Also wird auch
        // nichts abgebildet, sondern abgelehnt, und die Ablehnung sagt dem
        // Menschen, wo er hingesehen hat.
        for confusable: Character in ["I", "L", "O", "U"] {
            #expect(!DeviceLinkCode.alphabet.contains(confusable),
                    "\(confusable) darf im Alphabet nicht vorkommen")
        }
        #expect(DeviceLinkCode.normalized("IBCDEFGHJKMNPQRSTVWXYZAB") == nil)
        #expect(DeviceLinkCode.normalized("1BCDEFGHJKMNPQRSTVWXYZAB") == nil, "keine Ziffern")
        #expect(DeviceLinkCode.alphabet.allSatisfy { $0.isLetter }, "nur Buchstaben")
        #expect(DeviceLinkCode.alphabet.count == 22)
    }

    @Test("zu kurz, zu lang oder fremdes Zeichen ist KEIN Code")
    func anythingElseIsNotACode() {
        #expect(DeviceLinkCode.normalized(String(Self.sample.dropLast())) == nil, "eins zu kurz")
        #expect(DeviceLinkCode.normalized(Self.sample + "C") == nil, "eins zu lang")
        #expect(DeviceLinkCode.normalized("ABCDEFGHJKMNPQRSTVWXY!B") == nil, "fremdes Zeichen")
        #expect(DeviceLinkCode.normalized("") == nil)
        // Ein zu kurzer Code darf nicht durchgereicht werden: die
        // Entschluesselung koennte danach nur noch "falscher Schluessel"
        // sagen, und der Mensch sucht den Fehler an der falschen Stelle.
        #expect(!DeviceLinkCode.isCode(String(Self.sample.dropLast())))
    }

    // MARK: - Die Erzeugung

    @Test("verzerrende Bytes werden VERWORFEN, und zwar gemessen an der FUNKTION")
    func biasingBytesAreRejected() throws {
        // 22 teilt 256 nicht. Wer `byte % 22` rechnet, macht die ersten
        // vierzehn Buchstaben haeufiger als die uebrigen acht.
        let alphabet = DeviceLinkCode.alphabet
        let ceiling = 256 - (256 % alphabet.count)
        #expect(ceiling == 242, "22 mal 11, die groesste ganze Vielfache unter 256")

        // Erschoepfend ueber ALLE 256 Byte-Werte, und zwar DURCH die
        // Funktion statt durch eine Nachbildung ihrer Rechnung. Ein
        // Zeuge, der `alphabet[byte % 22]` selbst bildet, misst die
        // Annahme; dieser misst, was der Code tut, und sieht deshalb auch
        // eine verschobene Verwerfungsgrenze.
        let filler = [UInt8](repeating: 0, count: DeviceLinkCode.length)
        for value in 0..<256 {
            let byte = UInt8(value)
            let code = try #require(DeviceLinkCode.code(fromRandomBytes: [byte] + filler))
            if value < ceiling {
                #expect(code.first == alphabet[value % alphabet.count],
                        "Byte \(value) muss den Buchstaben \(value % alphabet.count) geben")
            } else {
                // Verworfen: das erste Zeichen kommt aus dem naechsten Byte.
                #expect(code.first == alphabet[0],
                        "Byte \(value) haette verworfen werden muessen")
            }
        }

        // Und jeder Buchstabe ist ueber die Funktion erreichbar, keiner
        // faellt aus dem Alphabet heraus.
        var reachable: Set<Character> = []
        for value in 0..<ceiling {
            let code = try #require(DeviceLinkCode.code(fromRandomBytes: [UInt8(value)] + filler))
            reachable.insert(try #require(code.first))
        }
        #expect(reachable.count == alphabet.count, "erreichbar: \(reachable.count)")
    }

    @Test("zu wenig Zufall gibt KEINEN Code")
    func tooLittleRandomnessGivesNothing() {
        #expect(DeviceLinkCode.code(fromRandomBytes: []) == nil)
        #expect(DeviceLinkCode.code(fromRandomBytes: [1, 2, 3]) == nil)
        // Lauter verzerrende Bytes sind so gut wie keine.
        #expect(DeviceLinkCode.code(fromRandomBytes: [UInt8](repeating: 255, count: 200)) == nil)
    }

    @Test("die Staerke steht als Zahl da, nicht als Behauptung")
    func theStrengthIsANumber() {
        // 100 Bit. Wer das Alphabet kuerzt oder den Code verkuerzt, um die
        // Eingabe bequemer zu machen, reisst hier und liest den Grund: ein
        // kurzer Code waere offline durchsuchbar von dem, der den Block
        // ohnehin haelt.
        // 107 Bit. Wer das Alphabet kuerzt oder den Code verkuerzt, um die
        // Eingabe bequemer zu machen, reisst hier. Und die Eingabe wird
        // davon nicht bequemer: gemessen kostet die gemischte Form mit 20
        // Zeichen 28,5 Tastendruecke, diese mit 24 nur 24.
        #expect(DeviceLinkCode.entropyBits == 107)
        #expect(DeviceLinkCode.length == 24)
        #expect(DeviceLinkCode.entropyBits >= 100, "unter 100 Bit wird der Code durchsuchbar")
    }

    @Test("Rundlauf: erzeugt, gruppiert, wieder gelesen, derselbe Code")
    func roundTrip() throws {
        let bytes: [UInt8] = [21, 0, 17, 9, 4, 19, 20, 1, 12, 8, 3, 15,
                              11, 6, 18, 2, 13, 5, 10, 7, 16, 14, 9, 3]
        let code = try #require(DeviceLinkCode.code(fromRandomBytes: bytes))
        let written = DeviceLinkCode.grouped(code)
        #expect(written.contains("-"))
        #expect(DeviceLinkCode.normalized(written) == code)
        #expect(DeviceLinkCode.isCode(code))
    }

    // MARK: - Die Zusage, an der der Punkt haengt

    /// Ein Quelltext-Zaun, und er ist hier die einzige ehrliche Sicherung:
    /// ob ein Schluessel in Apples iCloud-Schluesselbund landet, sieht ein
    /// Verhaltensfall im Simulator nicht. Dieselbe Bauart wie beim
    /// Zeitvergleich, der `==` und `compare_digest` nicht unterscheiden kann.
    @Test("der Wiederherstellungs-Schluessel reist NIE ueber Apple")
    func theRecoveryKeyNeverTravelsThroughApple() throws {
        let door = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "DeviceLinkCodeStore.swift" })
        let text = try String(contentsOf: door, encoding: .utf8)
        // Die Tuer schreibt mit der Vorgabe, also geraete-lokal. Sie
        // uebergibt den Reise-Parameter nirgends, auch nicht mit false:
        // stuende er da, waere er eine Stellschraube, und eine Stellschraube
        // an dieser Stelle ist die Luecke selbst.
        #expect(!text.contains("synchronizable"),
                "die Schluessel-Tuer nennt den Reise-Parameter")
        // Seit S3 entsteht kein Code mehr: die Tuer liest und vergisst,
        // schreiben kann sie nicht.
        #expect(!text.contains("KeychainStore.save("), "die Tuer schreibt noch einen Code")
        #expect(text.contains("KeychainStore.load(") && text.contains("KeychainStore.delete("))

        // Und der Name des Schluessels lebt nur an dieser einen Stelle, damit
        // niemand ihn anderswo mit anderen Bedingungen schreibt.
        var holders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let body = try String(contentsOf: file, encoding: .utf8)
            if body.contains("deviceLinkCode") { holders.append(file.lastPathComponent) }
        }
        #expect(holders == ["DeviceLinkCodeStore.swift"], "Halter: \(holders.sorted())")
    }
}
#endif
