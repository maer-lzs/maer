// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A finished download control shows a state and deletes nothing when
/// tapped, for the album and the episode alike. The album's control deleted
/// the whole album on a tap; deleting now lives in the long press menu, on
/// the track rows and on the bar glyph itself, and in the glyph's named
/// VoiceOver action.
struct FinishedDownloadControlTests {
    /// The delete calls of a body that no VoiceOver action carries: the
    /// line before each call must open `.accessibilityAction(named:`.
    nonisolated static func unnamedDeletes(in body: String) -> Int {
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.indices.filter { index in
            let line = lines[index]
            guard line.contains("deleteDownload(") || line.contains("deleteAllDownloads(") else { return false }
            return index == 0 || !lines[index - 1].contains(".accessibilityAction(named:")
        }.count
    }

    /// The body of one type declaration: from its `struct` line to the next
    /// closing brace at the start of a line.
    nonisolated static func body(of type: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: {
            $0.firstMatch(of: #/^(?:private |fileprivate )?struct (\w+)\b/#).map { String($0.output.1) } == type
        }) else { return nil }
        guard let end = lines[start...].firstIndex(where: { $0.hasPrefix("}") }) else { return nil }
        return lines[start...end].map(IdQuestionDoorFenceTests.withoutComment).joined(separator: "\n")
    }

    static func source(_ path: String) throws -> String {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.path.hasSuffix(path) })
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("ein fertiger Download-Knopf loescht nichts, Album wie Folge", .needsTheSources)
    func aFinishedControlDeletesNothing() throws {
        let controls = [("Views/Music/MusicAlbumView.swift", "AlbumDownloadButton"),
                        ("Views/Podcasts/PodcastComponents.swift", "PodcastDownloadButton")]
        for (path, type) in controls {
            let body = try #require(Self.body(of: type, in: try Self.source(path)), "\(type) nicht gefunden")
            #expect(Self.unnamedDeletes(in: body) == 0, "\(type) loescht wieder beim Tippen")
        }
    }

    @Test("Langes Druecken auf das geladene Album-Symbol bietet die Loesch-Eintraege der Titelzeile, auch fuer VoiceOver", .needsTheSources)
    func theStoredAlbumGlyphOffersDelete() throws {
        let body = try #require(Self.body(of: "AlbumDownloadButton",
                                          in: try Self.source("Views/Music/MusicAlbumView.swift")))
        let open = try #require(body.range(of: "isDeletableDownload(itemId: itemId)"))
        let close = try #require(body.range(of: "} else if case .downloading", range: open.upperBound..<body.endIndex))
        let stored = String(body[open.upperBound..<close.lowerBound])
        #expect(stored.contains("\"arrow.down.circle.fill\""))
        #expect(stored.contains(".foregroundStyle(.secondary)"))
        #expect(!stored.contains(".green"))
        // The track rows' own entries, not a second delete.
        #expect(stored.contains(".contextMenu {"))
        #expect(stored.contains("AlbumDownloadMenuItems("))
        #expect(stored.contains(".accessibilityAction(named: Text(\"Delete Download\"))"))
        // A tap does nothing: the stored glyph is no button.
        #expect(!stored.contains("Button"))
    }

    @Test("Eichzeilen: nur ein Loeschen unter einer benannten VoiceOver-Handlung ist erlaubt")
    func onlyANamedActionMayDelete() {
        #expect(Self.unnamedDeletes(in: "Button { m.deleteDownload(itemId: i) } label: { x }") == 1)
        #expect(Self.unnamedDeletes(in: ".accessibilityAction(named: Text(\"Delete Download\")) {\n    m.deleteDownload(itemId: i)\n}") == 0)
        #expect(Self.unnamedDeletes(in: ".onTapGesture {\n    m.deleteDownload(itemId: i)\n}") == 1)
        #expect(Self.unnamedDeletes(in: "Image(systemName: \"x\")") == 0)
    }

    @Test("das Album wird ueber das Langdruck-Menue seiner Titel geloescht", .needsTheSources)
    func theAlbumIsDeletedFromTheLongPressMenu() throws {
        let page = try Self.source("Views/Music/MusicAlbumView.swift")
        let menu = try #require(Self.body(of: "AlbumDownloadMenuItems", in: page))
        #expect(menu.contains("deleteDownload(itemId: itemId)"), "das Menue traegt den Loesch-Eintrag nicht mehr")
        #expect(page.contains("AlbumDownloadMenuItems(itemId: item.id"), "die Albumseite ruft das Menue nicht mehr")
    }

    @Test("der Koerper-Finder schneidet genau einen Typ")
    func theBodyFinderCutsOneType() {
        let text = "struct A: View {\n    var body: some View { x.deleteDownload(itemId: i) }\n}\n\nprivate struct B {\n    let y = 1\n}\n"
        #expect(Self.body(of: "A", in: text)?.contains("deleteDownload(") == true)
        #expect(Self.body(of: "B", in: text)?.contains("deleteDownload(") == false)
        #expect(Self.body(of: "AB", in: text) == nil)
    }
}
#endif
