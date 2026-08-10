// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The id namespace decides which page an item can reach. A family without a
/// mapping used to fall into "book" silently, which sent a netlabel album to
/// the audiobook tab and opened an empty page.
struct MediaFamilyTests {
    @Test("every known namespace has a defined family — none falls through")
    func everyNamespaceIsAssigned() {
        let expected: [String: MediaFamily] = [
            "rss:feed:ep": .podcast,
            "abspod:1": .podcast,
            "sub:song:1": .music,
            "jf:1": .music,
            "radio:1": .radio,
            "lv:176": .catalog,
            "lva:OTRR_Gunsmoke": .catalog,
            "jam:1886432": .catalog,
            "gut:12345": .catalog,
            "local:file": .book,
        ]
        for (id, family) in expected {
            #expect(MediaFamily.of(id) == family, "\(id) must map to \(family)")
        }
        // A bare id is an Audiobookshelf item — the only family without a
        // namespace of its own.
        #expect(MediaFamily.of("8f2a-uuid") == .book)
    }

    @Test("an unknown namespace stays unknown instead of counting as a book")
    func unknownIsVisible() {
        #expect(MediaFamily.of("newthing:42") == .unknown)
        #expect(!PlayerSourceTargets.isBook("newthing:42"),
                "an unknown family must not inherit the book affordance")
    }

    @Test("the catalogue families are books to nobody")
    func catalogIsNotABook() {
        for id in ["lv:176", "lva:x", "jam:1", "gut:2"] {
            #expect(!PlayerSourceTargets.isBook(id))
            #expect(PlayerSourceTargets.isCatalog(id))
        }
    }

    @Test("every prefix the catalogue owns is listed in the family map")
    func catalogPrefixesStayInSync() {
        let mapped = Set(MediaFamily.prefixes(for: .catalog))
        let owned: Set<String> = [FreeCatalog.librivoxPrefix, FreeCatalog.archivePrefix,
                                  FreeCatalog.jamendoPrefix, FreeCatalog.gutenbergPrefix]
        #expect(mapped == owned, "a new catalogue namespace must be assigned here too")
    }
}
#endif
