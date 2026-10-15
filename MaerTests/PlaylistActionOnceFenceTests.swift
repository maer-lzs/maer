// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Add to Playlist" appears ONCE per menu. `CatalogQueueButtons` already
/// carries the playlist action, so a menu that places it next to a second
/// `AddToPlaylistButton` shows the entry twice (the catalog track row did).
/// The fence counts both building blocks inside every context menu and
/// every `Menu` block in the views.
struct PlaylistActionOnceFenceTests {
    /// The playlist actions inside each menu block of one file, with the
    /// line the block starts on.
    nonisolated static func playlistActionsPerMenu(in text: String) -> [(line: Int, count: Int)] {
        var result: [(Int, Int)] = []
        let chars = Array(text)
        var search = text.startIndex
        while let range = text.range(of: #"(\.contextMenu|\bMenu)\s*\{"#, options: .regularExpression, range: search..<text.endIndex) {
            var depth = 1
            var index = text.distance(from: text.startIndex, to: range.upperBound)
            let start = index
            while index < chars.count, depth > 0 {
                if chars[index] == "{" { depth += 1 } else if chars[index] == "}" { depth -= 1 }
                index += 1
            }
            let block = String(chars[start..<index])
            let count = block.components(separatedBy: "AddToPlaylistButton(").count - 1
                + block.components(separatedBy: "CatalogQueueButtons(").count - 1
            result.append((text[..<range.lowerBound].filter { $0 == "\n" }.count + 1, count))
            search = range.upperBound
        }
        return result
    }

    @Test("Zur Playlist hinzufuegen steht in jedem Menue genau einmal", .needsTheSources)
    func onePlaylistActionPerMenu() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for menu in Self.playlistActionsPerMenu(in: text) where menu.count > 1 {
                offenders.append("\(file.lastPathComponent):\(menu.line) carries \(menu.count) playlist actions")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("Der Pruefer saehe das Doppel (Rot-Probe)")
    func checkerSeesTheDouble() {
        let double = """
        .contextMenu {
            CatalogQueueButtons(itemId: songId)
            AddToPlaylistButton(itemId: songId, knownTitles: [:])
        }
        """
        #expect(Self.playlistActionsPerMenu(in: double).map(\.count) == [2])
        let single = ".contextMenu {\n    CatalogQueueButtons(itemId: songId, knownTitles: [:])\n}\n"
        #expect(Self.playlistActionsPerMenu(in: single).map(\.count) == [1])
        let none = "Menu {\n    Button(\"Play\") {}\n}\n"
        #expect(Self.playlistActionsPerMenu(in: none).map(\.count) == [0])
    }
}
#endif
