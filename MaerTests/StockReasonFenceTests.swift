// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Zaun mit begruendetem Bestand ist besser als einer ohne, aber jede
/// Begruendung darin ist eine AUSSAGE UEBER DEN CODE, und die kann altern
/// oder von Anfang an danebenliegen. Belegte Faelle: ein Satz behauptete
/// „kein neuer Beobachter", wo einer entstand; eine Begruendung nannte
/// einen Helfer ohne eigenes `self`, wo ein `ViewModifier` mit eigenem
/// `body` stand. Jedes Mal war der BAU richtig und der Satz daneben
/// falsch, und keiner dieser Fehler wird je rot.
///
/// Der erste Versuch dagegen war ein Zaun, der Begruendungs-Absatz und
/// Bestand gegeneinander haelt. Er hat zwei Sachen gezeigt, beide gegen
/// sich selbst: er zwang einen WAHREN Satz zur Umformulierung (eine Notiz,
/// dass eine Datei einmal zu Unrecht im Bestand stand, stoerte ihn), und
/// er fuehrte eine Opt-in-Liste, also einen Fundort-Fix an genau der
/// Klasse, deren Lehre „die Klasse suchen, nicht den Fundort fixen" heisst.
///
/// Beides faellt weg, wenn der Grund gar nicht erst neben dem Eintrag
/// stehen kann, sondern DARIN: `[String: (count: Int, reason: String)]`.
/// Dann kann keine Begruendung von ihrem Eintrag abdriften, keine Datei
/// erfinden und keine verschweigen, und ein Fliesstext daneben ist wieder
/// frei. Die Form gab es im Repo schon (`AblageFenceTests`,
/// `PublicLogAddressFenceTests`); die zwei jungen Zaeune hatten eine
/// zweite erfunden und sind auf die bestehende gezogen.
///
/// Dieser Zaun haelt nur noch die FORM, und er SUCHT seine Kandidaten:
/// jede Testdatei mit einem Datei-Bestand fuehrt ihre Gruende im Eintrag
/// oder sagt ausdruecklich, dass sie keine fuehrt.
///
/// Einzelgruende zahlen sich aus, wo die Eintraege sich UNTERSCHEIDEN. Wo
/// ein Satz den ganzen Bestand deckt, gehoert er darueber und der Merker
/// sagt das: bei der Concurrency-Naht steht der Grund ohnehin AM FUNDORT
/// und wird dort erzwungen, ein Abbild hier waere eine zweite Stelle, die
/// abdriften kann. Der Merker ist keine Ausrede, er ist die sichtbare
/// Wahl; ohne ihn ist es nur nie jemandem aufgefallen.
struct StockReasonFenceTests {
    static let marker = "BESTAND OHNE EINZELGRUENDE:"

    /// Ein Datei-Bestand ist eine `static let`-Sammlung, die Dateinamen auf
    /// eine ZAHL abbildet, also auf eine erlaubte Menge. Drei Sorten fallen
    /// damit heraus, und das ist Absicht:
    ///
    /// - ein Zaun, der zwei Quelldateien bloss LIEST, hat keine Sammlung
    /// - `[String: String]` bildet auf einen Grund ab, ist also selbst schon
    ///   die begruendete Form
    /// - `[String: Set<String>]` ist eine Datenzuordnung, kein Bestand
    static func fileStocks(in text: String) -> [(declaration: String, names: Set<String>, excused: Bool)] {
        var out: [(String, Set<String>, Bool)] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let head = lines[index].trimmingCharacters(in: .whitespaces)
            guard !head.hasPrefix("//"), head.contains("static let"),
                  head.contains("[String"), head.contains("Int") else { index += 1; continue }
            // Der Merker gehoert an den BESTAND, nicht an die Datei: eine
            // Datei kann mehrere fuehren, und ein Merker fuer alle wuerde
            // einen kuenftigen, begruendbaren still mitbefreien. Er steht
            // also im Kommentarblock unmittelbar darueber.
            var excused = false
            var above = index - 1
            while above >= 0 {
                let line = lines[above].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("//") || line.isEmpty else { break }
                if line.contains(Self.marker) { excused = true; break }
                above -= 1
            }
            var names: Set<String> = []
            var cursor = index
            while cursor < lines.count {
                let body = lines[cursor].trimmingCharacters(in: .whitespaces)
                for token in body.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "+") })
                where token.hasSuffix(".swift") {
                    names.insert(String(token))
                }
                // Die Deklaration endet, wo ihre Klammer schliesst; steht sie
                // ganz in einer Zeile, ist sie mit dieser Zeile zu Ende. Ohne
                // das las der Sucher in die naechste Deklaration hinein und
                // schrieb einem leeren Bestand fremde Namen zu.
                if body.hasSuffix("]") || (cursor > index && body.hasPrefix("]")) { break }
                cursor += 1
            }
            if names.count >= 2 { out.append((head, names, excused)) }
            index = cursor + 1
        }
        return out
    }

    @Test("Jeder Datei-Bestand traegt seine Gruende im Eintrag, oder sagt dass er keine hat", .needsTheTests)
    func everyFileStockCarriesItsReasons() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var offenders: [String] = []
        var candidates = 0
        // Die eigene Datei bleibt draussen, und zwar mit Grund: ihre
        // Bestaende sind Testdaten in Zeichenketten, keine Bestaende. Der
        // Sucher kann das nicht unterscheiden, und ihm das beizubringen
        // hiesse, ihn an einem Sonderfall auszurichten. Die Zusicherung auf
        // die Kandidatenzahl darunter faengt es, falls die Ausnahme je mehr
        // verdeckt als sie soll.
        let own = URL(fileURLWithPath: #filePath).lastPathComponent
        for file in files where file.lastPathComponent != own {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stocks = Self.fileStocks(in: text)
            guard !stocks.isEmpty else { continue }
            candidates += stocks.count
            for stock in stocks where !stock.excused && !stock.declaration.contains("reason:") {
                offenders.append("\(file.lastPathComponent): \(stock.names.count) Dateien ohne Grund im Eintrag")
            }
        }
        // Ohne diese Zusicherung waere ein Sucher, der nichts mehr findet,
        // ein gruener Zaun ohne Messung.
        #expect(candidates >= 7, "der Kandidaten-Sucher findet fast nichts: \(candidates)")
        #expect(offenders.isEmpty,
                """
                \(offenders). Ein Datei-Bestand traegt seinen Grund im Eintrag \
                ([String: (count: Int, reason: String)]), damit er nicht von ihm \
                abdriften kann. Wer keine Gruende fuehren will, schreibt \
                „\(Self.marker) <warum nicht>" in die Datei
                """)
    }

    @Test("Der Sucher findet Bestaende und keine gelesenen Pfade")
    func theSearcherFindsStocksNotPaths() {
        let stock = """
            struct A {
                nonisolated static let stock: [String: Int] = [
                    "Foo.swift": 1,
                    "Bar.swift": 2,
                ]
            }
            """
        #expect(Self.fileStocks(in: stock).first?.names == ["Foo.swift", "Bar.swift"])
        // Rot-Probe in die andere Richtung: zwei GELESENE Pfade sind kein
        // Bestand, und ein Zaun, der nur greppt, soll nicht in die Pflicht.
        let paths = """
            func check() throws {
                let a = try source("Sources/Views/Foo.swift")
                let b = try source("Sources/Views/Bar.swift")
            }
            """
        #expect(Self.fileStocks(in: paths).isEmpty)
        // Und ein einzelner Name ist noch keine Sammlung.
        let single = "    static let home: [String: Int] = [\"Foo.swift\": 1]"
        #expect(Self.fileStocks(in: single).isEmpty)
    }

    @Test("Der Merker befreit den BESTAND, nicht die Datei")
    func theExcuseBindsToTheStockNotTheFile() {
        // Eine Datei kann mehrere Bestaende fuehren. Ein Merker irgendwo in
        // ihr wuerde einen kuenftigen, begruendbaren still mitbefreien; das
        // ist die Klasse „die Ausnahme ist grobkoerniger als der gepruefte
        // Gegenstand".
        let two = """
            struct A {
                // \(Self.marker) ein reines Inventar
                nonisolated static let alt: [String: Int] = [
                    "Foo.swift": 1,
                    "Bar.swift": 2,
                ]

                nonisolated static let neu: [String: Int] = [
                    "Baz.swift": 1,
                    "Qux.swift": 2,
                ]
            }
            """
        let stocks = Self.fileStocks(in: two)
        #expect(stocks.count == 2)
        #expect(stocks.first?.excused == true)
        #expect(stocks.last?.excused == false, "der Merker des ersten Bestands befreit den zweiten mit")
    }
}
#endif
