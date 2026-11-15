// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sentence that asks to unlock the device names what was asked for.
struct UnlockSentenceTests {
    @Test("the kind as a table: an episode by its id, a song or a station as a title, everything else as a book")
    func theKindAsATable() {
        #expect(UnlockSentence.kind(itemId: "rss:feed:guid", isMusic: false) == .episode)
        #expect(UnlockSentence.kind(itemId: "abspod:item:episode", isMusic: false) == .episode)
        #expect(UnlockSentence.kind(itemId: "radio:station", isMusic: false) == .title)
        #expect(UnlockSentence.kind(itemId: "sub:song", isMusic: true) == .title)
        #expect(UnlockSentence.kind(itemId: "li_book", isMusic: false) == .book)
        #expect(UnlockSentence.kind(itemId: "", isMusic: false) == .book, "no title yet reads as a book")
    }

    @Test("each kind has its own sentence")
    func eachKindHasItsSentence() {
        let sentences = [UnlockSentence.Kind.book, .episode, .title].map(UnlockSentence.of)
        #expect(Set(sentences).count == 3, "two kinds say the same: \(sentences)")
        #expect(UnlockSentence.of(.book) == String(localized: "Unlock this device once to play this book."))
    }
}
#endif
