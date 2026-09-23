// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Nothing is offered that cannot be delivered: without the book no entry,
/// and without any entry no menu.
struct LibriVoxTakeoverOfferTests {
    static func book(rss: String?) -> LibriVoxBook {
        LibriVoxBook(id: "42", title: "T", language: nil, totaltimesecs: nil, url_iarchive: nil,
                     url_librivox: nil, url_rss: rss, authors: nil, sections: [], genres: nil)
    }

    @Test("ohne Buch kein Angebot, auch mit Server-Bibliotheken")
    func withoutTheBookNothingIsOffered() {
        let offers = LibriVoxTakeoverOffer.offers(book: nil, hasServerLibraries: true)
        #expect(offers == .init(server: false, feed: false))
        #expect(!offers.any, "ohne Eintrag kein Menue")
    }

    @Test("mit Buch: der Server nur mit Bibliothek, der Feed nur mit Adresse")
    func withTheBookEachOfferNeedsItsMeans() {
        #expect(LibriVoxTakeoverOffer.offers(book: Self.book(rss: "https://f"), hasServerLibraries: true)
                == .init(server: true, feed: true))
        #expect(LibriVoxTakeoverOffer.offers(book: Self.book(rss: nil), hasServerLibraries: true)
                == .init(server: true, feed: false))
        #expect(LibriVoxTakeoverOffer.offers(book: Self.book(rss: ""), hasServerLibraries: false)
                == .init(server: false, feed: false))
        #expect(LibriVoxTakeoverOffer.offers(book: Self.book(rss: "https://f"), hasServerLibraries: false)
                == .init(server: false, feed: true))
    }
}
#endif
