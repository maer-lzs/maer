// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The answers of the catalogue shelves as entries, below the views. The
/// register is filled here and not by a page, and the curation of archive
/// documents stands once. The pages used to curate and enter it themselves,
/// the same chain in three places plus the popular list.
///
/// The network answer still crosses a page's task group as its raw payload
/// (documents are Sendable, entries are not declared so); the entries are
/// made here, on the main actor, when the answer arrives.
@MainActor
enum CatalogShelfEntries {
    typealias Shelf = (items: [LibraryItem], total: Int?)

    /// The ONE curation of archive documents for a source: the denylist,
    /// plus the separation from LibriVox where the source asks for it.
    /// Order is kept.
    static func curated(_ docs: [ArchivePopularDoc], source: CatalogSource) -> [ArchivePopularDoc] {
        docs.filter {
            FreeCatalog.isCuratedArchiveDoc(
                $0, separatingFromLibriVox: FreeCatalog.separatesFromLibriVox(source))
        }
    }

    /// Curated documents as entries of the register, those with a cover
    /// (`CatalogCoverRule.browsable`; every builder here is browsing).
    static func books(_ docs: [ArchivePopularDoc], source: CatalogSource,
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        CatalogCoverRule.browsable(curated(docs, source: source).compactMap { register.remember(popular: $0) }, register: register)
    }

    /// Gutenberg's music works as tiles of the classical area.
    static func gutenbergMusic(_ entries: [CatalogStockEntry],
                               register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        entries.compactMap { register.remember(gutenbergMusic: $0) }
    }

    /// The day's row of Gutenberg music from the kept stock: art music for
    /// the classical page, the rest for the music page.
    static func gutenbergMusicLane(classical: Bool, stocks: CatalogStockService = .shared) -> [LibraryItem] {
        guard AppStorageKeys.gutenbergSourceActive, let stock = stocks.stock(CatalogSource.gutenberg.rawValue) else { return [] }
        return gutenbergMusic(GutenbergMusic.lane(stock, rows: RowPreview.limit, on: Date(), classical: classical))
    }

    /// Gutenberg books as entries; they need no curation.
    static func books(_ books: [GutenbergClient.Book],
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        CatalogCoverRule.browsable(books.compactMap { register.remember(gutenberg: $0) }, register: register)
    }

    /// Music documents as entries, uncurated as before: the book curation
    /// never applied to the music areas.
    static func music(_ docs: [ArchivePopularDoc],
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        CatalogCoverRule.browsable(docs.compactMap { register.remember(popular: $0) }, register: register)
    }

    /// One shelf answer as entries, nil where the source has no shelf.
    /// `collectionsLast` keeps multi-author collections behind the single
    /// works: findable, but not on the first places. A malus, not an
    /// exclusion; it empties no shelf.
    static func shelf(_ answer: CatalogShelfSource.Answer?, source: CatalogSource,
                      collectionsLast: Bool = false,
                      register: FreeCatalogProvider = .shared) -> Shelf? {
        switch answer {
        case .archive(let docs, let total):
            guard collectionsLast else { return (books(docs, source: source, register: register), total) }
            let kept = curated(docs, source: source)
            let single = kept.filter { !FreeCatalog.isMultiAuthorCollection($0) }
            let collections = kept.filter { FreeCatalog.isMultiAuthorCollection($0) }
            return (CatalogCoverRule.browsable((single + collections).compactMap { register.remember(popular: $0) }, register: register), total)
        case .gutenberg(let found, let total):
            return (books(found, register: register), total)
        case .unsupported, .none:
            return nil
        }
    }
}
