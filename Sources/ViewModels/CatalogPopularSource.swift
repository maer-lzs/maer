// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import SwiftUI
import OSLog

/// The ONE load path of the popularity list. The source page's preview row
/// and the full page behind its chevron both ask through here. Otherwise the
/// row on top shows a different excerpt than the page behind it.
///
/// A failure is NOT exhaustion: `failed` carries its reason, `cancelled`
/// stays silent, and only `loaded` may end the list.
@MainActor
enum CatalogPopularSource {
    enum Answer {
        case loaded(items: [LibraryItem], unfiltered: Bool, atEnd: Bool)
        case failed(String)
        case cancelled
    }

    static func seed(source: CatalogSource, store: FreeCatalogStore) -> [LibraryItem] {
        switch source {
        case .librivox:     store.sourceRows.librivoxPopular
        case .archiveBooks: store.sourceRows.archiveBooks
        case .gutenberg:    store.sourceRows.gutenberg
        case .oldTimeRadio: store.sourceRows.oldTimeRadio
        default:            []
        }
    }

    /// `clients` and `languages` are the live ones by default; a witness
    /// hands in its own and the page never reaches the network.
    static func page(source: CatalogSource, page: Int, rows: Int, unfiltered: Bool,
                     using clients: CatalogClients = .live,
                     languages: [String] = SuggestionLanguages.current()) async -> Answer {
        let provider = FreeCatalogProvider.shared
        let codes = languages
        var fresh: [LibraryItem] = []
        var fallback = unfiltered
        var atEnd = false
        func curated(_ docs: [ArchivePopularDoc]) -> [LibraryItem] {
            docs.filter {
                FreeCatalog.isCuratedArchiveDoc(
                    $0, separatingFromLibriVox: FreeCatalog.separatesFromLibriVox(source))
            }.compactMap { provider.remember(popular: $0) }
        }
        do {
            switch source {
            case .librivox:
                let docs = try await clients.archive.popularLibriVoxByLanguage(rows, codes, rows, page)
                fresh = curated(docs)
                if docs.count < rows { atEnd = true }
            case .archiveBooks:
                // The fallback is a SESSION state. Once fallen back,
                // deeper pages browse the unfiltered corpus too.
                let result = try await clients.archive.audiobooksOutsideLibriVox(rows, codes, page, unfiltered)
                fallback = result.unfiltered
                fresh = curated(result.docs)
                if result.docs.count < rows { atEnd = true }
            case .gutenberg:
                var books = try await clients.gutenberg.audiobooks(unfiltered ? [] : codes, page)
                if books.isEmpty, page == 1, !codes.isEmpty, !unfiltered {
                    books = try await clients.gutenberg.audiobooks([], 1)
                    if !books.isEmpty { fallback = true }
                }
                fresh = books.compactMap { provider.remember(gutenberg: $0) }
                if books.isEmpty { atEnd = true }
            case .oldTimeRadio:
                let docs = try await clients.archive.popularOldTimeRadio(rows, page)
                fresh = curated(docs)
                if docs.count < rows { atEnd = true }
            default:
                atEnd = true
            }
        } catch {
            guard let reason = FreeCatalog.failureReason(error) else { return .cancelled }
            return .failed(reason)
        }
        return .loaded(items: fresh, unfiltered: fallback, atEnd: atEnd)
    }
}
