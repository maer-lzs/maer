// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import SwiftUI
import OSLog

/// The load layer of the MERGED catalog page. One pass,
/// all catalog sources in parallel, one visible failure per source. The
/// per-view @State loaders of the two old pages collapse into this; the feed
/// sources are static curation and need no loading at all.
@MainActor
enum CatalogSourceLoader {
    struct SourceRows {
        var librivoxNew: [LibraryItem] = []
        var librivoxPopular: [LibraryItem] = []
        var archiveBooks: [LibraryItem] = []
        var gutenberg: [LibraryItem] = []
        var oldTimeRadio: [LibraryItem] = []
        /// Failed sources WITH the short reason (log + error
        /// line). Cancellations never land here. A cancelled task is "not
        /// loaded yet", not a broken source.
        var failures: [CatalogSource: String] = [:]
    }

    /// Books one source failure: a real failure carries its reason (A3),
    /// a cancellation carries none and stays silent (A1). A torn-down `.task`
    /// is "not loaded yet", never a broken source.
    private static func book(_ reason: String?, _ source: CatalogSource,
                             into failures: inout [CatalogSource: String]) {
        guard let reason else { return }
        failures[source] = reason
    }

    /// `onRow` hands each finished row to the store IMMEDIATELY. The
    /// returned value stays the complete result (callers that want the whole
    /// pass keep working unchanged); the callback is what makes the first row
    /// appear in seconds instead of after the slowest source.
    typealias RowSink = @MainActor (@escaping @MainActor (inout SourceRows) -> Void) -> Void

    /// One finished FETCH, carrying its own row identity. The
    /// children of the group do network work only. The decoded payload is
    /// `Sendable`, the mapping to `LibraryItem` stays on the main actor where
    /// the provider lives. `reason` is the already-classified failure text
    /// (nil = success, or a cancellation, which stays silent).
    private enum Fetched: Sendable {
        case librivoxNew([LibriVoxBook]?, String?)
        case librivoxPopular([ArchivePopularDoc]?, String?)
        case archiveBooks([ArchivePopularDoc]?, String?)
        case oldTimeRadio([ArchivePopularDoc]?, String?)
        case gutenberg([GutenbergClient.Book]?, String?)
    }

    /// Runs one source fetch and classifies its outcome, so the group can
    /// hand back a `Sendable` value instead of an error existential.
    nonisolated private static func attempt<T: Sendable>(
        _ op: @escaping @Sendable () async throws -> T) async -> (T?, String?) {
        do { return (try await op(), nil) } catch { return (nil, FreeCatalog.failureReason(error)) }
    }

    /// `clients` and `gates` are the live ones by default; a witness hands
    /// in its own and the pass never reaches the network. `keptStock` is the
    /// kept stock of a source, the same one its own page reads.
    static func load(onRow: RowSink? = nil, using clients: CatalogClients = .live,
                     gates: CatalogGates = .live,
                     keptStock: (CatalogSource) -> CatalogStock? = { CatalogStockService.shared.stock($0.rawValue) })
        async -> SourceRows {
        var rows = SourceRows()
        #if DEBUG
        if UITestSeed.isActive { return rows }
        #endif
        let provider = FreeCatalogProvider.shared
        let codes = gates.languages
        let librivoxOn = gates.librivox
        let archiveOn = gates.archiveBooks
        let archive = clients.archive
        let gutenberg = clients.gutenberg
        let librivox = clients.librivox

        // Daily rotation of the POPULARITY rows: the same sorting, but a
        // different page of the top tenth each day. The newest-first row does
        // NOT rotate, because sorting by date makes it fresh daily anyway.
        // Stocks measured: LibriVox 21,711 · archive audiobooks 4,257 · OTR
        // (licensed) 2,309.
        let today = Date()
        // With a kept Gutenberg stock the row is the stock's browse page in its
        // popularity order, turned into tiles by the same conversion as every
        // shelf of the Gutenberg page, and gutendex is not asked. Without one
        // it asks gutendex as before.
        let gutenbergFromStock: [LibraryItem]? = gates.gutenberg
            ? keptStock(.gutenberg)
                .flatMap { CatalogShelfSource.localBrowse(rows: RowPreview.limit, stock: $0, source: .gutenberg, on: today) }
                .flatMap { CatalogShelfEntries.shelf($0, source: .gutenberg, collectionsLast: true, register: provider)?.items }
            : nil
        if let gutenbergFromStock {
            rows.gutenberg = gutenbergFromStock
            await onRow?({ $0.gutenberg = gutenbergFromStock })
        }
        let lvPage = CatalogRotation.page(total: 21_711, rowSize: 12, on: today)
        let iaPage = CatalogRotation.page(total: 4_257, rowSize: 12, on: today)
        let otrPage = CatalogRotation.page(total: 2_309, rowSize: 12, on: today)

        // ONE pass, sources concurrent. And published in the
        // order they FINISH. `async let` plus sequential `await` publishes in
        // START order: the three fast rows (measured ~1 s each) waited for the
        // slowest one, so publishing per row could not take effect at all.
        // A source that is switched off starts no request now. The task is
        // never created instead of being started and discarded.
        await withTaskGroup(of: Fetched.self) { group in
            if librivoxOn {
                group.addTask {
                    let (books, reason) = await attempt {
                        try await librivox.newBooks(120, 40) }
                    return .librivoxNew(books, reason)
                }
                group.addTask {
                    let (docs, reason) = await attempt {
                        try await archive.popularLibriVoxByLanguage(12, codes, 12, lvPage) }
                    return .librivoxPopular(docs, reason)
                }
            }
            // Gutenberg keeps its own fallback ladder (its two pages stay
            // sequential). Its own gate too: it used to ride the LibriVox
            // one, which would leave its new source switch dead.
            if gates.gutenberg, gutenbergFromStock == nil {
                group.addTask {
                    let (books, reason) = await attempt { () -> [GutenbergClient.Book] in
                        var books: [GutenbergClient.Book] = []
                        for page in 1...2 {
                            let hit = try await gutenberg.audiobooks(codes, page)
                            books += hit
                            if hit.isEmpty { break }
                        }
                        if books.isEmpty, !codes.isEmpty {
                            books = try await gutenberg.audiobooks([], 1)
                        }
                        return books
                    }
                    return .gutenberg(books, reason)
                }
            }
            if archiveOn {
                group.addTask {
                    let (docs, reason) = await attempt {
                        try await archive.audiobooksOutsideLibriVox(12, codes, iaPage, false).docs }
                    return .archiveBooks(docs, reason)
                }
                // The row used to exist only when English was among the
                // chosen languages, and the two rows above filter by the
                // same codes. On a German-only device that emptied THREE
                // catalog rows at once (measured on the device: lvPop=0
                // ia=0 otr=0); the language choice silently became a
                // catalog switch. Same decision as for the shelves: a
                // collection that carries nothing in the chosen languages
                // is shown anyway rather than hidden; ordering may prefer
                // a language, existence may not depend on it.
                group.addTask {
                    let (docs, reason) = await attempt {
                        try await archive.popularOldTimeRadio(12, otrPage) }
                    return .oldTimeRadio(docs, reason)
                }
            }
            for await finished in group {
                switch finished {
                case .librivoxNew(let books, let reason):
                    book(reason, .librivox, into: &rows.failures)
                    guard let books else { continue }
                    let filtered = FreeCatalog.filterByLanguages(books, codes: codes)
                    rows.librivoxNew = filtered.prefix(RowPreview.limit).map { provider.remember(book: $0) }
                    let fresh = rows.librivoxNew
                    await onRow?({ $0.librivoxNew = fresh })
                case .librivoxPopular(let docs, let reason):
                    book(reason, .librivox, into: &rows.failures)
                    guard let docs else { continue }
                    rows.librivoxPopular = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
                    let fresh = rows.librivoxPopular
                    await onRow?({ $0.librivoxPopular = fresh })
                case .archiveBooks(let docs, let reason):
                    book(reason, .archiveBooks, into: &rows.failures)
                    guard let docs else { continue }
                    rows.archiveBooks = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
                    let fresh = rows.archiveBooks
                    await onRow?({ $0.archiveBooks = fresh })
                case .oldTimeRadio(let docs, let reason):
                    book(reason, .oldTimeRadio, into: &rows.failures)
                    guard let docs else { continue }
                    rows.oldTimeRadio = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
                    let fresh = rows.oldTimeRadio
                    await onRow?({ $0.oldTimeRadio = fresh })
                case .gutenberg(let books, let reason):
                    book(reason, .gutenberg, into: &rows.failures)
                    guard let books else { continue }
                    rows.gutenberg = books.compactMap { provider.remember(gutenberg: $0) }
                    let fresh = rows.gutenberg
                    await onRow?({ $0.gutenberg = fresh })
                }
            }
        }
        for (source, reason) in rows.failures {
            // Reason is short and URL-free by construction (failureReason).
            Logger.library.error("FREECAT source=\(source.rawValue, privacy: .public) FAILED: \(reason, privacy: .public)")
        }
        Logger.library.notice("FREECAT sources lvNew=\(rows.librivoxNew.count) lvPop=\(rows.librivoxPopular.count) ia=\(rows.archiveBooks.count) gut=\(rows.gutenberg.count) otr=\(rows.oldTimeRadio.count)")
        return rows
    }
}
