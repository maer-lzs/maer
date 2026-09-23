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

    /// Curated documents as entries of the register.
    static func books(_ docs: [ArchivePopularDoc], source: CatalogSource,
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        curated(docs, source: source).compactMap { register.remember(popular: $0) }
    }

    /// Gutenberg books as entries; they need no curation.
    static func books(_ books: [GutenbergClient.Book],
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        books.compactMap { register.remember(gutenberg: $0) }
    }

    /// Music documents as entries, uncurated as before: the book curation
    /// never applied to the music areas.
    static func music(_ docs: [ArchivePopularDoc],
                      register: FreeCatalogProvider = .shared) -> [LibraryItem] {
        docs.compactMap { register.remember(popular: $0) }
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
            return ((single + collections).compactMap { register.remember(popular: $0) }, total)
        case .gutenberg(let found, let total):
            return (books(found, register: register), total)
        case .unsupported, .none:
            return nil
        }
    }
}
