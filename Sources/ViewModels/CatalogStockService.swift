// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Fetches and keeps the catalogue stocks, and SAYS what it is doing.
///
/// The first fetch runs on the first visit of a surface, one collection at
/// a time. Not as a block behind every surface: whoever only listens to
/// podcasts never fetches anything, and a collection nobody opens costs
/// nothing.
@MainActor
final class CatalogStockService: ObservableObject {
    static let shared = CatalogStockService()

    /// What the user is told. Every case is a sentence the surface can show;
    /// none of them is a silent wait.
    enum State: Equatable {
        case idle
        /// The Wi-Fi gate is closed. It says WHY, and that it will come.
        case waitingForWiFi
        /// Without Wi-Fi it ASKS instead of refusing, and it names the
        /// measured size so the answer can be an informed one.
        case asksForCellular(megabytes: Int)
        case loading(done: Int, total: Int)
        case ready(Int)
        /// WITHOUT a reason on purpose: the reason belongs in the log, the
        /// surface gets a sentence a reader can act on. A code, a URL or a
        /// task id on a page is a developer talking to himself.
        case failed
    }

    @Published private(set) var states: [String: State] = [:]

    private var running: Set<String> = []
    /// Collections the user allowed on cellular, for THIS session. Not
    /// persisted on purpose: a standing permission to spend a data plan
    /// would be invisible from then on.
    private var cellularAllowed: Set<String> = []
    private let store = CatalogStockStore.shared

    func state(_ surface: String) -> State { states[surface] ?? .idle }

    /// The answer to the cellular question. Yes fetches now; no leaves the
    /// old way carrying the surface, exactly as before.
    func allowCellular(surface: String, archiveQuery: String?) {
        cellularAllowed.insert(surface)
        states[surface] = .idle
        Task { await ensureStock(surface: surface, archiveQuery: archiveQuery) }
    }

    /// The kept stock of a collection, or nil while there is none. Readers
    /// fall back to the day store, which stays the fallback rather than
    /// becoming dead code.
    func stock(_ surface: String) -> CatalogStock? { store.load(surface: surface) }

    /// Called by a surface when it appears. Does nothing when the stock is
    /// there and belongs to today.
    func ensureStock(surface: String, archiveQuery: String?) async {
        guard !running.contains(surface) else { return }
        let kept = store.load(surface: surface)
        if let kept, !CatalogStockRules.needsRefresh(kept) {
            states[surface] = .ready(kept.entries.count)
            return
        }
        // The gate sits BEFORE the fetch, and it is the same one the
        // automatic download uses. Unattended traffic never runs on the
        // user's data plan.
        if await !NetworkStatus.isOnWiFi() {
            // Asking beats refusing: whoever wants it on cellular may have
            // it, but only after being told what it costs. The consent is
            // per SESSION and per collection, never a standing permission
            // that nobody can see afterwards.
            guard cellularAllowed.contains(surface) else {
                if let megabytes = CatalogStockFetch.transferMegabytes(surface: surface) {
                    states[surface] = .asksForCellular(megabytes: megabytes)
                } else {
                    states[surface] = .waitingForWiFi
                }
                Logger.library.notice("STOCK \(surface, privacy: .public) asks about cellular")
                return
            }
        }
        running.insert(surface)
        defer { running.remove(surface) }
        do {
            if let kept {
                try await refresh(kept, archiveQuery: archiveQuery)
            } else {
                try await firstFetch(surface: surface, archiveQuery: archiveQuery)
            }
        } catch {
            report(error, surface: surface)
        }
    }

    /// What a failed run says, and to whom.
    ///
    /// Three things went wrong here at once and they have one root: the
    /// surface printed whatever the error stringified to. A cancelled task
    /// became a red line, a `URLError -1005` became a sentence, and one
    /// NSError put its whole description on the page, including the scrape
    /// URL with its cursor token.
    private func report(_ error: Error, surface: String) {
        // A cancelled background run is not a failure of the surface. It
        // says NOTHING, and it leaves the surface in the state it had.
        guard !error.isCancellation else {
            if case .loading = state(surface) { states[surface] = .idle }
            return
        }
        // The technical reason goes to the LOG. The surface gets a sentence
        // in the user's language, and never a URL, a code or a task id.
        let technical = FreeCatalog.failureReason(error) ?? String(describing: type(of: error))
        Logger.library.error("STOCK \(surface, privacy: .public) failed: \(technical, privacy: .public)")
        // And a surface that HAS content is not in total failure. Whoever
        // already holds a stock keeps being told what it holds.
        if let kept = store.load(surface: surface) {
            states[surface] = .ready(kept.entries.count)
            return
        }
        states[surface] = .failed
    }

    private func firstFetch(surface: String, archiveQuery: String?) async throws {
        states[surface] = .loading(done: 0, total: 0)
        if let archiveQuery {
            // The run RESUMES. An app switch or a closed app costs the last
            // slice, never the run: what arrived is written down with the
            // cursor it stood at, and the next visit continues there.
            let angefangen = store.load(surface: surface)
            var entries: [CatalogStockEntry] = angefangen?.entries ?? []
            var cursor: String? = angefangen?.fetchCursor
            var total = 0
            repeat {
                let slice = try await CatalogStockFetch.archiveSlice(query: archiveQuery,
                                                                     cursor: cursor)
                entries += slice.entries
                total = max(total, slice.total)
                cursor = slice.cursor
                // Published BETWEEN slices, so the number the user sees is
                // the number that is actually in, not an estimate.
                states[surface] = .loading(done: entries.count, total: total)
                // Written down BEFORE the next slice is asked. An
                // interruption between two slices therefore keeps everything
                // that came before it.
                if cursor != nil { keepPartial(surface: surface, entries: entries, cursor: cursor) }
            } while cursor != nil && !Task.isCancelled
            try finish(surface: surface, entries: entries, previous: nil)
        } else {
            let entries = try await CatalogStockFetch.gutenbergStock()
            states[surface] = .loading(done: entries.count, total: entries.count)
            try finish(surface: surface, entries: entries, previous: nil)
        }
    }

    /// Only what is new. One query per day and collection.
    private func refresh(_ kept: CatalogStock, archiveQuery: String?) async throws {
        let surface = kept.surface
        // Every thirty days the whole collection comes again: the download
        // counts drift, and a run that only ADDS what is new would never
        // correct them. A failed one leaves the old stock standing.
        if CatalogStockRules.needsFullRefetch(kept) {
            try await firstFetch(surface: surface, archiveQuery: archiveQuery)
            return
        }
        states[surface] = .loading(done: kept.entries.count, total: kept.entries.count)
        let fresh: [CatalogStockEntry]
        if let archiveQuery, let watermark = kept.watermark {
            fresh = try await CatalogStockFetch.archiveSince(query: archiveQuery,
                                                             watermark: watermark).entries
        } else if archiveQuery == nil {
            fresh = try await CatalogStockFetch.gutenbergStock()
        } else {
            fresh = try await CatalogStockFetch.archiveSlice(query: archiveQuery!).entries
        }
        // An empty answer is a clean answer and keeps everything. That is
        // the class where a generator exited cleanly and left a dead file.
        let merged = CatalogStockRules.merged(kept.entries, with: fresh)
        try finish(surface: surface, entries: merged, previous: kept.watermark)
    }

    /// An unfinished stock, written down so the next run continues instead
    /// of starting over. It carries the cursor, and therefore says of
    /// itself that it is not whole.
    private func keepPartial(surface: String, entries: [CatalogStockEntry], cursor: String?) {
        var stock = store.load(surface: surface)
            ?? CatalogStock(surface: surface, takenAt: 0, watermark: nil, entries: [])
        stock.entries = entries
        stock.fetchCursor = cursor
        // takenAt stays at zero until the run is whole: a partial stock must
        // never look like today's answer to the refresh rule.
        stock.takenAt = 0
        _ = store.save(stock)
    }

    private func finish(surface: String, entries: [CatalogStockEntry],
                        previous: String?) throws {
        guard !entries.isEmpty else {
            // Nothing fetched and nothing kept: not a stock, and above all
            // not an empty one written over a good one. Whoever HAS a stock
            // keeps being told what it holds instead of a total failure.
            if let kept = store.load(surface: surface) {
                states[surface] = .ready(kept.entries.count)
            } else {
                states[surface] = .failed
            }
            return
        }
        var stock = store.load(surface: surface)
            ?? CatalogStock(surface: surface, takenAt: 0, watermark: nil, entries: [])
        stock.entries = entries
        stock.takenAt = Date().timeIntervalSince1970
        stock.watermark = CatalogStockFetch.watermark(from: entries, previous: previous)
        // The run is whole, so the resume mark goes away.
        stock.fetchCursor = nil
        guard store.save(stock) else {
            states[surface] = .failed
            return
        }
        states[surface] = .ready(entries.count)
        Logger.library.notice("STOCK \(surface, privacy: .public) kept \(entries.count) entries")
        // Gutenberg's popularity is not in the dump. It is gathered
        // afterwards, in the background, and NOTHING waits for it.
        if surface == CatalogSource.gutenberg.rawValue {
            Task { await self.gatherGutenbergPopularity() }
        }
    }

    /// The enumeration behind Gutenberg's shelves, page by page.
    ///
    /// It runs in the background and no surface ever waits for it: until it
    /// is through, the shelves keep asking the service exactly as before.
    /// Every page is written down before the next is asked, so an
    /// interruption costs one page rather than the run. A failure leaves
    /// what was reached standing.
    ///
    /// Serial on purpose. The cold pages are the service COMPUTING, and
    /// thirty-six at once is the shape that had another endpoint refuse the
    /// connection.
    func gatherGutenbergPopularity() async {
        let surface = CatalogSource.gutenberg.rawValue
        guard var stock = store.load(surface: surface) else { return }
        guard stock.popularityComplete != true else { return }
        guard await NetworkStatus.isOnWiFi() else { return }
        var page = stock.popularityPage ?? 1
        var counts = stock.popularity ?? [:]
        while !Task.isCancelled {
            do {
                let answer = try await CatalogStockFetch.gutenbergPopularityPage(page)
                counts.merge(answer.counts) { _, new in new }
                stock.popularity = counts
                stock.popularityPage = page + 1
                stock.popularityComplete = !answer.hasMore
                guard store.save(stock) else { return }
                if !answer.hasMore {
                    Logger.library.notice("STOCK gutenberg popularity complete: \(counts.count) works")
                    return
                }
                page += 1
            } catch {
                // What was reached stays. The next run continues at the page
                // that failed, and the shelves keep asking the service until
                // the ranking is whole.
                Logger.library.error("STOCK gutenberg popularity stopped at page \(page): \(String(describing: error), privacy: .public)")
                return
            }
        }
    }
}
