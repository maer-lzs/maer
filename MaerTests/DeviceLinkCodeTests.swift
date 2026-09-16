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

    @Test("zwanzig Zeichen werden fuenf Gruppen, alles andere bleibt wie es ist")
    func groupingIsFiveBlocksOrNothing() {
        let code = "0123456789ABCDEFGHJK"
        #expect(code.count == DeviceLinkCode.length)
        #expect(DeviceLinkCode.grouped(code) == "0123-4567-89AB-CDEF-GHJK")
        // Eine falsche Laenge bekommt KEINE vertraute Gestalt: sonst sieht
        // ein kaputter Wert aus wie ein richtiger.
        #expect(DeviceLinkCode.grouped("0123") == "0123")
        #expect(DeviceLinkCode.grouped("") == "")
    }

    @Test("gelesen wird, was ein Mensch tippt: Striche, Leerzeichen, Kleinschrift")
    func readingAcceptsWhatPeopleType() {
        let want = "0123456789ABCDEFGHJK"
        #expect(DeviceLinkCode.normalized("0123-4567-89AB-CDEF-GHJK") == want)
        #expect(DeviceLinkCode.normalized("0123 4567 89ab cdef ghjk") == want)
        #expect(DeviceLinkCode.normalized("0123456789abcdefghjk") == want)
    }

    @Test("die vier verwechselbaren Zeichen werden auf die Ziffer abgebildet, die sie zeigen")
    func confusableShapesMapToTheDigitTheyLookLike() {
        // I und L sehen aus wie 1, O wie 0. Wer tippt was er sieht, hat
        // recht, auch wenn er falsch sieht.
        #expect(DeviceLinkCode.normalized("I23456789ABCDEFGHJK0") == "123456789ABCDEFGHJK0")
        #expect(DeviceLinkCode.normalized("L23456789ABCDEFGHJK0") == "123456789ABCDEFGHJK0")
        #expect(DeviceLinkCode.normalized("O23456789ABCDEFGHJK1") == "023456789ABCDEFGHJK1")
        // Und die Gegenrichtung: das Alphabet enthaelt diese Zeichen NICHT,
        // sonst waere die Abbildung mehrdeutig statt hilfreich.
        for confusable: Character in ["I", "L", "O", "U"] {
            #expect(!DeviceLinkCode.alphabet.contains(confusable),
                    "\(confusable) darf im Alphabet nicht vorkommen")
        }
    }

    @Test("zu kurz, zu lang oder fremdes Zeichen ist KEIN Code")
    func anythingElseIsNotACode() {
        #expect(DeviceLinkCode.normalized("0123456789ABCDEFGHJ") == nil, "eins zu kurz")
        #expect(DeviceLinkCode.normalized("0123456789ABCDEFGHJKL") == nil, "eins zu lang")
        #expect(DeviceLinkCode.normalized("0123456789ABCDEFGH!K") == nil, "fremdes Zeichen")
        #expect(DeviceLinkCode.normalized("") == nil)
        // Ein zu kurzer Code darf nicht durchgereicht werden: die
        // Entschluesselung koennte danach nur noch "falscher Schluessel"
        // sagen, und der Mensch sucht den Fehler an der falschen Stelle.
        #expect(!DeviceLinkCode.isCode("0123456789ABCDEFGHJ"))
    }

    // MARK: - Die Erzeugung

    @Test("jedes Byte benennt genau ein Zeichen, ohne Verzerrung")
    func everyByteNamesOneCharacterWithoutBias() throws {
        // Die unteren fuenf Bits nehmen genau 32 Werte an, das Alphabet hat
        // 32 Eintraege. Deshalb braucht es keine Verwerfungs-Schleife, und
        // deshalb ist jedes Zeichen gleich wahrscheinlich.
        #expect(DeviceLinkCode.alphabet.count == 32)
        let bytes = (0..<DeviceLinkCode.length).map { UInt8($0) }
        let code = try #require(DeviceLinkCode.code(fromRandomBytes: bytes))
        #expect(code == "0123456789ABCDEFGHJK")
        // Die oberen drei Bits duerfen nichts aendern.
        let shifted = (0..<DeviceLinkCode.length).map { UInt8($0) | 0b1110_0000 }
        #expect(DeviceLinkCode.code(fromRandomBytes: shifted) == code)
        // Alle 32 Zeichen sind erreichbar.
        let all = (0..<32).map { UInt8($0) } + [UInt8](repeating: 0, count: 0)
        let reachable = Set((DeviceLinkCode.code(fromRandomBytes: all) ?? "").map { $0 })
        #expect(reachable.count == DeviceLinkCode.length,
                "die ersten zwanzig von 32 Werten geben zwanzig verschiedene Zeichen")
    }

    @Test("zu wenig Zufall gibt KEINEN Code")
    func tooLittleRandomnessGivesNothing() {
        #expect(DeviceLinkCode.code(fromRandomBytes: []) == nil)
        #expect(DeviceLinkCode.code(fromRandomBytes: [1, 2, 3]) == nil)
    }

    @Test("die Staerke steht als Zahl da, nicht als Behauptung")
    func theStrengthIsANumber() {
        // 100 Bit. Wer das Alphabet kuerzt oder den Code verkuerzt, um die
        // Eingabe bequemer zu machen, reisst hier und liest den Grund: ein
        // kurzer Code waere offline durchsuchbar von dem, der den Block
        // ohnehin haelt.
        #expect(DeviceLinkCode.entropyBits == 100)
        #expect(DeviceLinkCode.length == 20)
    }

    @Test("Rundlauf: erzeugt, gruppiert, wieder gelesen, derselbe Code")
    func roundTrip() throws {
        let bytes: [UInt8] = [31, 0, 17, 9, 4, 22, 30, 1, 12, 8, 3, 25, 11, 6, 19, 2, 28, 15, 5, 10]
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
        #expect(text.contains("KeychainStore.save("), "sie schreibt ueberhaupt in den Schluesselbund")

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
