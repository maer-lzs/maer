// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The introduction of a catalogue page says what is true of the page and
/// stays left of an open fold.
struct CatalogIntroTests {
    @Test("die Einleitung endet vor dem Falz wie die linke Spalte, ohne Falz nimmt sie die Seite")
    func theIntroEndsBeforeTheFold() {
        // The open Duo: window 951, fold 455.5 to 495.5, side column 84.
        let open = FoldSplit.leadingHalf(contentMinX: 0, contentWidth: 867, fold: 455.5...495.5, windowWidth: 951)
        #expect(open == 447.5)
        // Its text, inside its own gutter, ends the fold distance before the band.
        #expect(open.map { $0 - FoldSplit.pageGutter } == 455.5 - FoldSplit.foldDistance)
        #expect(FoldSplit.leadingHalf(contentMinX: 0, contentWidth: 466, fold: nil, windowWidth: 466) == nil)
        // A page that begins right of the fold has no leading column to keep to.
        #expect(FoldSplit.leadingHalf(contentMinX: 500, contentWidth: 367, fold: 455.5...495.5, windowWidth: 951) == 0)
    }

    @Test("kein Satz einer Einleitung verspricht eine Angabe auf der Kachel")
    func noIntroPromisesAnythingOnATile() {
        #expect(ArchiveMusicCatalog.netlabels.headerNote
                == String(localized: "Netlabel releases under Creative Commons licences, from the Internet Archive."))
        let intros = [ArchiveMusicCatalog.netlabels.headerNote, ArchiveMusicCatalog.shellacAll.headerNote]
            + ArchiveMusicCatalog.shellacShelves.map(\.headerNote)
            + CatalogSource.allCases.compactMap(\.majorityRightsNote)
        for intro in intros {
            #expect(!intro.lowercased().contains("tile") && !intro.lowercased().contains("kachel"), "\(intro)")
        }
    }

    @Test("jede Einleitung einer Katalogseite und der Rechtehinweis bleiben links vom Falz", .needsTheSources)
    func everyIntroKeepsLeftOfTheFold() throws {
        func text(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .replacing(#/\s+/#, with: " ")
        }
        let music = try text("Sources/Views/Music/ArchiveMusicPages.swift")
        #expect(music.contains("Text(area.headerNote) .font(.caption) .foregroundStyle(.secondary) .padding(.horizontal) .foldLeadingHalf()"))
        #expect(music.contains("The recording year is the only rights information the source states.\") .font(.caption) .foregroundStyle(.secondary) .padding(.horizontal) .foldLeadingHalf()"))
        let source = try text("Sources/Views/CatalogSourcePage.swift")
        #expect(source.contains("Text(note) .font(.caption) .foregroundStyle(.secondary) .padding(.horizontal) .foldLeadingHalf()"))
        let note = try #require(try text("Sources/Views/TabContentLayout.swift")
            .components(separatedBy: "struct ArchiveRightsNote: View {").last)
        #expect(note.contains(".accessibilityElement(children: .combine) .foldLeadingHalf() } }"))
    }
}
#endif
