// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The index runs of the music tiles are countable in a device log: one
/// line per network question, the answer unchanged.
struct IndexRunLineTests {
    struct Refused: Error {}

    @Test("die Zeile hat die Form der Metadaten-Zeile")
    func theLineHasTheCatalogueShape() {
        #expect(IndexRunLine.line(kind: "mosaic", ms: 12, reason: "ok") == "INDEXRUN kind=mosaic ms=12 reason=ok")
    }

    @Test("gemessen antwortet wie try?: der Wert, oder nil bei jedem Fehler")
    func measuredAnswersLikeTry() async {
        #expect(await IndexRunLine.measured("mosaic", id: "x") { 3 } == 3)
        #expect(await IndexRunLine.measured("mosaic", id: "x") { () throws -> Int in throw Refused() } == nil)
    }

    /// The tiles' network questions, each with its counting line.
    nonisolated static let sites: [(file: String, kind: String)] = [
        ("Sources/Providers/JellyfinProvider.swift", "IndexRunLine.measured(\"artistInfo\""),
        ("Sources/Providers/JellyfinProvider.swift", "IndexRunLine.measured(\"mosaic\""),
        ("Sources/Providers/SubsonicProvider.swift", "IndexRunLine.measured(\"artistInfo\""),
        ("Sources/Providers/SubsonicProvider.swift", "IndexRunLine.measured(\"mosaic\""),
        ("Sources/Networking/ArtistPortraitService.swift", "IndexRunLine.write(kind: \"portrait\""),
    ]

    @Test("jede Netzfrage einer Musik-Kachel schreibt ihre Zaehlzeile", .needsTheSources)
    func everyTileQuestionIsCounted() throws {
        for site in Self.sites {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent(site.file), encoding: .utf8)
            #expect(text.components(separatedBy: site.kind).count - 1 == 1, "\(site.file) zaehlt \(site.kind) nicht")
        }
    }
}
#endif
