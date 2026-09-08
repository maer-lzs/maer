// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GOAL 3.0, Punkt 1: die Suchansicht ruft keinen Provider und entscheidet
/// kein Ziel. Beides lag vorher bei ihr: sie fragte den Musik-Provider und
/// das Podcast-Verzeichnis selbst, und wohin ein Treffer führt, entschied
/// `LibraryView`, ein Rufer, der mit Suchen nichts zu tun hat. Der Zaun
/// hält die Naht; die Rot-Probe steht im Test selbst, weil ein Zaun, der
/// nur „0 Verstöße" meldet, nichts beweist.
struct SearchDoorFenceTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Die Provider-Namen, die eine Suchfläche nie selbst kennen soll.
    private static let providerReaches = [
        "AppSession.shared.musicProvider",
        "ITunesDirectory(",
        "PodcastIndexDirectory(",
        "FreeCatalogProvider.shared.libraryItem",
        "RadioProvider.shared.search",
    ]

    static func reaches(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let body = lines.joined(separator: "\n")
        return providerReaches.filter { body.contains($0) }
    }

    @Test("Die Suchansicht fragt keinen Provider selbst")
    func theSearchViewAsksNoProvider() throws {
        #expect(Self.reaches(in: try Self.source("Sources/Views/SearchScreen.swift")).isEmpty)
        // Rot-Probe in beide Richtungen: der Prüfer sieht den Griff…
        #expect(Self.reaches(in: "let x = AppSession.shared.musicProvider") == ["AppSession.shared.musicProvider"])
        // …und einen Kommentar darüber sieht er NICHT (die Lehre aus dem
        // Zaun, der an seiner eigenen Begründung riss).
        #expect(Self.reaches(in: "// uses AppSession.shared.musicProvider").isEmpty)
    }

    @Test("Die Ansicht entscheidet kein Ziel mehr: kein switch über die Trefferart")
    func theViewDecidesNoTarget() throws {
        // `LibraryView` führt das Ziel aus, aber die ENTSCHEIDUNG steht in
        // `SearchRouting`. Erkennungsmerkmal ist der Griff auf die ART.
        let library = try Self.source("Sources/Views/LibraryView.swift")
        #expect(!library.contains("switch result.kind"))
        #expect(library.contains("SearchDoor.target"))
    }

    @Test("Jede Trefferart hat ein benanntes Ziel")
    func everyKindHasATarget() {
        // Kein Zufallsergebnis: die Regel ist erschöpfend über die Art, und
        // dieser Fall fährt jede einmal, damit eine neue Art nicht still
        // ins Leere führt.
        let lookups = SearchLookups(item: { _ in true }, catalogHasParts: { _ in false },
                                    catalogKnows: { _ in true }, artistId: { _ in "a1" },
                                    artistKnown: { _ in true })
        for kind in SearchResult.Kind.allCases {
            let result = SearchResult(id: "id", kind: kind, title: "T")
            #expect(SearchRouting.target(for: result, lookups: lookups) != .unavailable,
                    "eine Trefferart ohne Ziel: \(kind.rawValue)")
        }
    }
}
#endif
