// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Zeuge liest keine Tatsache seiner UMGEBUNG.
///
/// `ExternalSource.isSwitchable`, `ExternalSources.switchable` und
/// `ExternalSources.disableAll` gibt es in zwei Fassungen: eine nimmt
/// „traegt dieser Bau einen PodcastIndex-Schluessel" als Eingang, die
/// bequeme liest die Tatsache selbst aus `AppStorageKeys`. Fuer die App ist
/// die bequeme richtig, sie WILL die Wirklichkeit. Fuer einen Zeugen ist sie
/// ein stiller Fehler: der Schluessel liegt nicht im Repo, also traegt ihn
/// die eine Maschine und die andere nicht, und derselbe Quelltext ist hier
/// gruen und dort rot. Gemessen an einem Fall, der auf einer Maschine mit
/// Schluessel elf Quellen wandern sah und auf einer ohne zehn.
///
/// Der Bestand ist NULL: in `MaerTests` nennt jeder Aufruf die Tatsache
/// ausdruecklich. Die einzige Ausnahme ist DIESE Datei, weil sie die
/// verbotenen Formen als Suchwoerter tragen muss.
struct ExternalSourcesWitnessFenceTests {
    private static let selfName = "ExternalSourcesWitnessFenceTests.swift"

    /// Quelltext einer Testdatei ohne Kommentarzeilen, Leerraum zusammengezogen.
    /// Ohne das Zusammenziehen prueft der Sucher die Zeilenlaenge statt der
    /// Aussage und reisst am naechsten Formatierer.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func testFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let all = try FileManager.default.contentsOfDirectory(at: root,
                                                              includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "swift" && $0.lastPathComponent != Self.selfName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Das Argument eines Aufrufs, von der oeffnenden bis zur passenden
    /// schliessenden Klammer. Die Frage ist damit LOKAL: sie sieht nur den
    /// Aufruf, den sie erklaert, nie seine Nachbarschaft.
    private func argumentsOfCalls(named name: String, in code: String) -> [String] {
        var found: [String] = []
        var rest = Substring(code)
        while let hit = rest.range(of: name + "(") {
            var depth = 1
            var index = hit.upperBound
            var argument = ""
            while index < rest.endIndex, depth > 0 {
                let character = rest[index]
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1; if depth == 0 { break } }
                argument.append(character)
                index = rest.index(after: index)
            }
            found.append(argument)
            rest = rest[hit.upperBound...]
        }
        return found
    }

    @Test("Kein Zeuge laesst die PodcastIndex-Tatsache aus der Umgebung kommen")
    func noWitnessReadsTheConfiguredFactFromItsEnvironment() throws {
        var offenders: [String] = []
        var explicitCalls = 0

        for file in try testFiles() {
            let text = try code(of: file)
            let name = file.lastPathComponent

            for argument in argumentsOfCalls(named: "ExternalSources.disableAll", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): disableAll ohne die Tatsache") }
            }
            for argument in argumentsOfCalls(named: "ExternalSources.switchable", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): switchable ohne die Tatsache") }
            }
            for argument in argumentsOfCalls(named: "isSwitchable", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): isSwitchable ohne die Tatsache") }
            }
            // Die EIGENSCHAFTS-Fassungen tragen keine Klammer, der Aufruf-Sucher
            // sieht sie also nie. Sie sind genau so gefaehrlich.
            for form in ["ExternalSources.switchable.", "ExternalSources.switchable ",
                         ".isSwitchable ", ".isSwitchable)", ".isSwitchable,"] where text.contains(form) {
                offenders.append("\(name): \(form.trimmingCharacters(in: .whitespaces)) liest die Umgebung")
            }
        }

        #expect(offenders.isEmpty,
                "ein Zeuge liest die PodcastIndex-Tatsache selbst: \(offenders.sorted())")
        // Ohne diese Zusicherung waere ein Sucher, der nichts mehr findet,
        // ein gruener Zaun ohne Messung.
        #expect(explicitCalls >= 3,
                "der Sucher findet keine Aufrufe mehr, er misst nichts (gefunden: \(explicitCalls))")
    }
}
#endif
