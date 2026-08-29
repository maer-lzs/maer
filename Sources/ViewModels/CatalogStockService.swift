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
        case loading(done: Int, total: Int)
        case ready(Int)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    private var running: Set<String> = []
    private let store = CatalogStockStore.shared

    func state(_ surface: String) -> State { states[surface] ?? .idle }

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
        guard await NetworkStatus.isOnWiFi() else {
            states[surface] = .waitingForWiFi
            Logger.library.notice("STOCK \(surface, privacy: .public) waits for Wi-Fi")
            return
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
            // Regel 3 and Invariante 3: the stock stays whatever it was, and
            // the surface says why it is not fresher.
            let reason = FreeCatalog.failureReason(error) ?? String(describing: error)
            states[surface] = .failed(reason)
            Logger.library.error("STOCK \(surface, privacy: .public) failed: \(reason, privacy: .public)")
        }
    }

    private func firstFetch(surface: String, archiveQuery: String?) async throws {
        states[surface] = .loading(done: 0, total: 0)
        if let archiveQuery {
            var entries: [CatalogStockEntry] = []
            var cursor: String?
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

    private func finish(surface: String, entries: [CatalogStockEntry],
                        previous: String?) throws {
        guard !entries.isEmpty else {
            // Nothing fetched and nothing kept: not a stock, and above all
            // not an empty one written over a good one.
            states[surface] = .failed(String(localized: "No entries received."))
            return
        }
        let stock = CatalogStock(surface: surface,
                                 takenAt: Date().timeIntervalSince1970,
                                 watermark: CatalogStockFetch.watermark(from: entries,
                                                                        previous: previous),
                                 entries: entries)
        guard store.save(stock) else {
            states[surface] = .failed(String(localized: "The stock could not be saved."))
            return
        }
        states[surface] = .ready(entries.count)
        Logger.library.notice("STOCK \(surface, privacy: .public) kept \(entries.count) entries")
    }
}
