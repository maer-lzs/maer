// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sentence a source gives when it cannot be asked names the cause that
/// really holds. Measured before this existed: the test button answered
/// "Enter server, username and password" to somebody whose server, username
/// and password were all filled in, while the source's own switch was off.
struct SourceReadinessTests {
    @Test("die Ursache, die wirklich gilt, und nur sie")
    func theCauseThatReallyHolds() {
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, address: "   ", username: "u") == .address,
                "eine Adresse aus Leerzeichen ist keine")
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, address: "https://s", username: "") == .account)
        // Der gemessene Fall: alles ausgefuellt, nur der Schalter ist aus.
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, address: "https://s", username: "u") == .switchedOff)
        #expect(SourceReadiness.missing(active: true, sourceEnabled: true, address: "https://s", username: "u") == nil)
    }

    /// **Der Fall, der F7 ausgeloest hat.** `active` ist ZUSAMMENGESETZT
    /// (Quellenschalter und Reiter, bei manchen Quellen dazu „bedient sie
    /// diese Art ueberhaupt"). Wer den Schalter anlaesst und nur den Reiter
    /// ausschaltet, bekam den Satz „der Schalter darueber ist aus" ueber
    /// einen Schalter, der an war.
    @Test("Schalter AN und Bereich aus nennt nicht den Schalter")
    func theSwitchIsNotBlamedWhenOnlyTheAreaIsOff() {
        let urteil = SourceReadiness.missing(active: false, sourceEnabled: true,
                                             address: "https://s", username: "u")
        #expect(urteil == .noAreaOn)
        #expect(urteil != .switchedOff, "der eingeschaltete Schalter wird als aus gemeldet")
        // Und die Gegenrichtung bleibt, wie sie war: ist der Schalter wirklich
        // aus, heisst es weiterhin so.
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false,
                                        address: "https://s", username: "u") == .switchedOff)
        // Der Satz nennt den Schalter dann auch nicht mehr.
        #expect(SourceReadiness.noAreaOn.sentence != SourceReadiness.switchedOff.sentence)
    }

    /// Die Reihenfolge ist die der Seite: erst was eingetippt wird, dann der
    /// Schalter darueber. Ein Satz, der zum Schalter schickt, waehrend die
    /// Felder darunter leer sind, schickt die Person zweimal.
    @Test("der Schalter wird zuletzt genannt, nicht zuerst")
    func theSwitchIsNamedLast() {
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: false, sourceEnabled: false, address: "https://s", username: "") == .account)
    }

    @Test("jede Ursache hat ihren eigenen Satz, und keiner zaehlt drei Dinge auf")
    func eachCauseHasItsOwnSentence() {
        let saetze = [SourceReadiness.address.sentence,
                      SourceReadiness.account.sentence,
                      SourceReadiness.switchedOff.sentence,
                      SourceReadiness.noAreaOn.sentence]
        // Sprachunabhaengig gefragt: der Wirt laeuft deutsch, ein Zeuge auf
        // ein englisches Wort haette die Uebersetzung gemessen und nicht die
        // Regel.
        #expect(Set(saetze).count == 4, "zwei Ursachen sagen dasselbe")
        for satz in saetze {
            #expect(satz.count > 10, "ein Satz, der nichts sagt")
            #expect(!satz.contains("server, username and password"),
                    "der alte Satz zaehlt drei Dinge auf und prueft eines")
        }
    }

    /// Der Zaun ueber die KLASSE: keine Quelle haelt sich ihren eigenen
    /// Bereitschafts-Satz. Beide Musik-Quellen hatten woertlich denselben.
    @Test("kein Provider baut sich seinen eigenen Bereitschafts-Satz", .needsTheSources)
    func noProviderBuildsItsOwnReadinessSentence() throws {
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = try #require(FileManager.default.enumerator(at: wurzel, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var stellen: [String] = []
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            if text.contains("Enter server, username and password") {
                stellen.append(datei.lastPathComponent)
            }
        }
        #expect(stellen.isEmpty, "der alte Sammelsatz steht wieder in \(stellen)")
    }

    /// **Der Zaun ueber die KLASSE aus F7:** wer eine Ursache benennt, muss
    /// den EINZELNEN Wert bekommen, nicht den zusammengesetzten. Die Regeln
    /// nehmen ihren Schalter deshalb aus einem `…EnabledValue`; kaeme dort
    /// wieder ein `…Active` an, saehe niemand es, weil beide `Bool` sind und
    /// der Unterschied erst auf der Flaeche auffaellt.
    @Test("kein Rufer reicht einen zusammengesetzten Wert als Schalter durch", .needsTheSources)
    func noCallerPassesAComposedValueAsTheSwitch() throws {
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = try #require(FileManager.default.enumerator(at: wurzel, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var stellen: [String] = []
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            // Der Leerraum wird ZUSAMMENGEZOGEN und das Argument endet am
            // Komma: ein Zeichenfenster haette hier die naechste Zeile
            // mitgelesen und meinen eigenen richtigen Aufruf als Verstoss
            // gemeldet (genau so ist dieser Zaun beim ersten Lauf gerissen).
            let flach = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            for argument in ["sourceEnabled:", "sourceOn:"] {
                var rest = Substring(flach)
                while let treffer = rest.range(of: argument) {
                    let danach = rest[treffer.upperBound...]
                    let wert = danach.prefix { $0 != "," && $0 != ")" }
                    if wert.contains("Active") {
                        stellen.append("\(datei.lastPathComponent): \(argument)\(wert)")
                    }
                    rest = danach
                }
            }
        }
        #expect(stellen.isEmpty, "ein zusammengesetzter Wert steht wieder als Schalter: \(stellen)")
    }
}
#endif
