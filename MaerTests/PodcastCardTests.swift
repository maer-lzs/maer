// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The episode card in Continue: title and the line under it stand together,
/// the room for a second title line lies below both.
struct PodcastCardTests {
    @Test("Titel und Zeile darunter stehen ohne Luecke, der Platz fuer die zweite Titelzeile steht darunter", .needsTheSources)
    func titleAndShowStandWithoutAGap() throws {
        let card = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastComponents.swift"),
                       encoding: .utf8))
        #expect(card.contains(".frame(maxWidth: .infinity, minHeight: titleMinHeight + 5 + showMinHeight, alignment: .topLeading)"))
        #expect(!card.contains(".lineLimit(2)\n                    .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)"),
                "the title reserves its second line right under itself again")
    }
}
#endif
