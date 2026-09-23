// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A genre shelf that could not be asked must not look like one the source
/// does not have. The catalog source page said so; the Jamendo page logged
/// the failure and let the row vanish without a word.
struct ShelvesFailedLineTests {
    @Test("die Zeile steht nur, wenn nichts ankam und etwas scheiterte")
    func theLineStandsOnlyWhenNothingArrivedAndSomethingFailed() {
        #expect(ShelvesFailedLine.isShown(arrived: 0, failed: 1))
        #expect(!ShelvesFailedLine.isShown(arrived: 2, failed: 1), "ein Teilausfall laesst die angekommenen sprechen")
        #expect(!ShelvesFailedLine.isShown(arrived: 0, failed: 0), "leer ohne Fehlschlag ist ehrlich leer")
    }

    /// Every page that collects shelf failures shows them through the one
    /// line, and the sentence lives only there.
    @Test("jede Seite, die Regal-Fehlschlaege sammelt, zeigt sie mit der einen Zeile", .needsTheSources)
    func everyPageThatCollectsFailuresShowsThem() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var collecting: [String] = []
        var silent: [String] = []
        var sentence: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(IdQuestionDoorFenceTests.withoutComment)
                .joined(separator: "\n")
            let name = file.lastPathComponent
            if code.contains("shelfFailures") {
                collecting.append(name)
                if !code.contains("ShelvesFailedLine.isShown(") { silent.append(name) }
            }
            if code.contains("Genres could not be loaded."), name != "ShelvesFailedLine.swift" {
                sentence.append(name)
            }
        }
        #expect(collecting.sorted() == ["CatalogSourcePage.swift", "MusicLibraryPages.swift"],
                "die Seiten mit Genre-Regalen: \(collecting)")
        #expect(silent.isEmpty, "eine Seite sammelt Fehlschlaege und zeigt sie nicht: \(silent)")
        #expect(sentence.isEmpty, "der Satz steht ausserhalb der einen Zeile: \(sentence)")
    }
}
#endif
