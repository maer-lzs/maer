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
        #expect(SourceReadiness.missing(active: true, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: true, address: "   ", username: "u") == .address,
                "eine Adresse aus Leerzeichen ist keine")
        #expect(SourceReadiness.missing(active: true, address: "https://s", username: "") == .account)
        // Der gemessene Fall: alles ausgefuellt, nur der Schalter ist aus.
        #expect(SourceReadiness.missing(active: false, address: "https://s", username: "u") == .switchedOff)
        #expect(SourceReadiness.missing(active: true, address: "https://s", username: "u") == nil)
    }

    /// Die Reihenfolge ist die der Seite: erst was eingetippt wird, dann der
    /// Schalter darueber. Ein Satz, der zum Schalter schickt, waehrend die
    /// Felder darunter leer sind, schickt die Person zweimal.
    @Test("der Schalter wird zuletzt genannt, nicht zuerst")
    func theSwitchIsNamedLast() {
        #expect(SourceReadiness.missing(active: false, address: "", username: "") == .address)
        #expect(SourceReadiness.missing(active: false, address: "https://s", username: "") == .account)
    }

    @Test("jede Ursache hat ihren eigenen Satz, und keiner zaehlt drei Dinge auf")
    func eachCauseHasItsOwnSentence() {
        let saetze = [SourceReadiness.address.sentence,
                      SourceReadiness.account.sentence,
                      SourceReadiness.switchedOff.sentence]
        // Sprachunabhaengig gefragt: der Wirt laeuft deutsch, ein Zeuge auf
        // ein englisches Wort haette die Uebersetzung gemessen und nicht die
        // Regel.
        #expect(Set(saetze).count == 3, "zwei Ursachen sagen dasselbe")
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
}
#endif
