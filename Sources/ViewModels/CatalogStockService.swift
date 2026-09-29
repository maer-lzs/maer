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
        /// The daily delta on a whole stock: it asks only for what came
        /// after the watermark. Its own state, because "Indexing n of n"
        /// during a delta read as the whole collection indexing again
        /// after every update.
        case refreshing(Int)
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
    func stock(_ surface: String) -> CatalogStock? { kept(surface)?.stock }

    /// The subject index of a kept stock, built once per session and
    /// surface. Shelves are answered from it instead of scanning the
    /// stock; measured, the scans were the page's whole switch time.
    func index(_ surface: String) -> CatalogStockIndex? { kept(surface)?.index }

    /// Decoded once, not per read. A catalogue page reads its stock on
    /// every body evaluation, and the archive audiobooks are a 13 MB
    /// file with 75.000 entries; decoding that per render was the
    /// second half of the switch time.
    private var keptStocks: [String: (stock: CatalogStock, index: CatalogStockIndex)] = [:]

    private func kept(_ surface: String) -> (stock: CatalogStock, index: CatalogStockIndex)? {
        // The held copy is only as good as its file. The lever that clears
        // derived stores removes the files directly, without passing
        // through here; a held copy that outlived its file would answer
        // for a stock the person just deleted, and the lever would still
        // report success. One stat call per read keeps the two in step.
        let fileStands = FileManager.default.fileExists(atPath: CatalogStockStore.fileURL(surface: surface).path)
        if let held = keptStocks[surface] {
            if fileStands { return held }
            keptStocks[surface] = nil
            return nil
        }
        guard fileStands, let stock = store.load(surface: surface) else { return nil }
        let held = (stock, CatalogStockIndex(stock: stock))
        keptStocks[surface] = held
        return held
    }

    /// Every write goes through here so the held copy can never outlive
    /// the file it mirrors. Internal, not private, so a witness can drive
    /// the service's own write path; the one that called itself here
    /// crashed the catalog page with a stack overflow on every write.
    func persist(_ stock: CatalogStock, caller: String = #function) -> Bool {
        keptStocks[stock.surface] = nil
        // Measurement at the write site: the load line only sees the state
        // at start, and a writer that carries an older snapshot back to the
        // file would stay invisible without this.
        Logger.library.notice("STOCK write surface=\(stock.surface, privacy: .public) entries=\(stock.entries.count) takenAt=\(Int(stock.takenAt), privacy: .public) cursor=\(stock.fetchCursor != nil ? "yes" : "no", privacy: .public) popPage=\(stock.popularityPage ?? 0) by=\(caller, privacy: .public)")
        return store.save(stock)
    }

    /// Called by a surface when it appears. Does nothing when the stock is
    /// there and belongs to today.
    /// When a surface last failed, so a fresh visit does not hammer a
    /// host that just refused connections (the measured -1004 class: the
    /// same source retried within seconds and failed identically).
    private var failedAt: [String: Date] = [:]
    /// When a HOST last refused us. Three of our surfaces are one
    /// archive.org, and the per-surface distance let each of them knock
    /// on a door the other two had just been thrown out of.
    // The host distance itself lives in `HostDistance`, shared with every
    // shelf and browse query; this service only asks and notes.
    static let retryFloorSeconds: TimeInterval = 30

    /// The runs start when the app opens, not when a page appears
    /// (ENTSCHEID, GT 3.2): every collection whose source is switched on
    /// runs through the same `ensureStock`, one after the other, with the
    /// same Wi-Fi gate and the same thirty-day rule, so a page is whole
    /// the first time it is opened. Collections with an unfinished run on
    /// this device go first.
    func startRuns(names: [String]? = nil,
                   allowed: (ExternalSource) -> Bool = { ExternalSources.isAllowed($0) }) async {
        // tragbar, weil ein fehlendes Verzeichnis heisst, dass noch nie ein Lauf etwas abgelegt hat
        let listed = names ?? ((try? FileManager.default.contentsOfDirectory(atPath: CatalogStockStore.directory.path)) ?? [])
        let surfaces = CatalogStockSurfaces.startOrder(known: CatalogStockSurfaces.known(inDirectoryNamed: listed))
        Logger.library.notice("STOCK start runs surfaces=\(surfaces.count)")
        for surface in surfaces {
            guard let fetch = CatalogStockSurfaces.fetch(for: surface) else {
                Logger.library.notice("STOCK \(surface, privacy: .public) has a file but no known run; skipped")
                continue
            }
            guard CatalogStockSurfaces.mayRun(surface: surface, allowed: allowed) else {
                Logger.library.notice("STOCK \(surface, privacy: .public) source is off; not started")
                continue
            }
            switch fetch {
            case .dump: await ensureStock(surface: surface, archiveQuery: nil)
            case .archive(let query): await ensureStock(surface: surface, archiveQuery: query)
            }
        }
    }

    func ensureStock(surface: String, archiveQuery: String?) async {
        // Every way out says why, so a run that did not happen can be told
        // from one that ended without a word.
        guard !running.contains(surface) else {
            Logger.library.notice("STOCK \(surface, privacy: .public) is running already; this occasion leaves it to that run")
            return
        }
        if let last = failedAt[surface],
           Date().timeIntervalSince(last) < Self.retryFloorSeconds {
            Logger.library.notice("STOCK \(surface, privacy: .public) waits: failed \(Int(Date().timeIntervalSince(last))) s ago")
            return
        }
        // The host-wide distance: a refusal by archive.org pauses ALL
        // archive surfaces, not just the one that ran into it.
        if HostDistance.isBlocked(CatalogHostGuard.host(forSurface: surface)) {
            Logger.library.notice("STOCK \(surface, privacy: .public) waits: host recently refused")
            return
        }
        let loaded = store.loadDiagnosed(surface: surface)
        let kept = loaded.stock
        // One line per surface and start, so "it indexes again after every
        // update" can be read as a file state and a verdict instead of guessed.
        let takenAt = kept.map { $0.takenAt > 0
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.takenAt)) : "0" } ?? "-"
        Logger.library.notice("STOCK load surface=\(surface, privacy: .public) file=\(loaded.file, privacy: .public) entries=\(kept?.entries.count ?? 0) takenAt=\(takenAt, privacy: .public) cursor=\(kept?.fetchCursor != nil ? "yes" : "no", privacy: .public) verdict=\(CatalogStockRules.loadVerdict(kept, isDump: archiveQuery == nil), privacy: .public)")
        if let kept, !CatalogStockRules.needsRun(kept, isDump: archiveQuery == nil) {
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
        // The RUN belongs to the service, not to the view that happened
        // to trigger it. It used to live in the view's task: every tab
        // switch cancelled it mid-slice, and a 77k stock paid the abort
        // tax on every switch (the marker saved the progress, the decided
        // rule says the run SURVIVES inside the app). Awaiting a task's
        // value does not forward the awaiter's cancellation, so a
        // disappearing view detaches only its observer.
        if let existing = runs[surface] {
            await existing.value
            return
        }
        let run = Task { [weak self] in
            guard let self else { return }
            defer { self.runs[surface] = nil }
            self.running.insert(surface)
            defer { self.running.remove(surface) }
            do {
                if let kept {
                    try await self.refresh(kept, archiveQuery: archiveQuery)
                } else {
                    try await self.firstFetch(surface: surface, archiveQuery: archiveQuery)
                }
            } catch {
                self.report(error, surface: surface)
            }
        }
        runs[surface] = run
        await run.value
    }

    /// The service-owned runs, one per surface. See ensureStock.
    private var runs: [String: Task<Void, Never>] = [:]

    /// What a failed run says, and to whom.
    ///
    /// Three things went wrong here at once and they have one root: the
    /// surface printed whatever the error stringified to. A cancelled task
    /// became a red line, a `URLError -1005` became a sentence, and one
    /// NSError put its whole description on the page, including the scrape
    /// URL with its cursor token.
    private func report(_ error: Error, surface: String) {
        // A cancelled background run is not a failure of the surface. It
        // says NOTHING on the page, and it leaves the surface in the state
        // it had. The LOG says it (a run that ended without a word cannot be
        // told from one that never ran); what it reached stays
        // on the disk for the next run.
        guard !error.isCancellation else {
            Logger.library.notice("STOCK \(surface, privacy: .public) run cancelled; what it reached stays for the next run")
            switch state(surface) {
            case .loading, .refreshing: states[surface] = .idle
            default: break
            }
            return
        }
        // The technical reason goes to the LOG. The surface gets a sentence
        // in the user's language, and never a URL, a code or a task id.
        let technical = FreeCatalog.logReason(error) ?? FailureReason.of(error)
        Logger.library.error("STOCK \(surface, privacy: .public) failed: \(technical, privacy: .public)")
        // And a surface that HAS content is not in total failure. Whoever
        // already holds a stock keeps being told what it holds.
        if let kept = store.load(surface: surface) {
            states[surface] = .ready(kept.entries.count)
            return
        }
        states[surface] = .failed
        failedAt[surface] = Date()
        // A transport refusal is the HOST's answer, not the surface's:
        // note it for every sibling that speaks to the same host. Only a
        // refusal; a timeout or a bad body says nothing about the host.
        if CatalogHostGuard.isRefusal(error) {
            HostDistance.note(CatalogHostGuard.host(forSurface: surface))
        }
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
            // A cancelled run must never book its torso as a whole stock:
            // finish would clear the resume mark and stamp takenAt, and the
            // thirty-day rule would hold the torso for the truth for a
            // month. The partial is already written down (with its cursor);
            // the throw lands in the cancellation branch and says nothing.
            try Task.checkCancellation()
            try finish(surface: surface, entries: entries, previous: nil)
        } else {
            let partial = CatalogStockFetch.DumpPartial(surface: surface)
            let entries = try await CatalogStockFetch.gutenbergStock(partial: partial)
            states[surface] = .loading(done: entries.count, total: entries.count)
            // The unfinished file goes only once the stock it made is on the
            // disk; until then the next run reads it instead of fetching it.
            if try finish(surface: surface, entries: entries, previous: nil) { partial.reset() }
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
        // The dump has no "new since": it is only ever fetched whole, above.
        guard let archiveQuery else {
            states[surface] = .ready(kept.entries.count)
            return
        }
        states[surface] = .refreshing(kept.entries.count)
        let fresh: [CatalogStockEntry]
        if let watermark = kept.watermark {
            fresh = try await CatalogStockFetch.archiveSince(query: archiveQuery,
                                                             watermark: watermark).entries
        } else {
            fresh = try await CatalogStockFetch.archiveSlice(query: archiveQuery).entries
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
        _ = persist(CatalogStockRules.partial(store.load(surface: surface), surface: surface,
                                              entries: entries, cursor: cursor))
    }

    /// Whether the stock stands on the disk now.
    @discardableResult
    private func finish(surface: String, entries: [CatalogStockEntry],
                        previous: String?) throws -> Bool {
        guard !entries.isEmpty else {
            // Nothing fetched and nothing kept: not a stock, and above all
            // not an empty one written over a good one. Whoever HAS a stock
            // keeps being told what it holds instead of a total failure.
            // And it says so: this end left no line, and a surface that never
            // got a stock could not be told from one that never ran.
            let kept = store.load(surface: surface)
            Logger.library.notice("STOCK \(surface, privacy: .public) run ended with no entries; kept=\(kept?.entries.count ?? 0)")
            states[surface] = kept.map { .ready($0.entries.count) } ?? .failed
            return false
        }
        var stock = store.load(surface: surface)
            ?? CatalogStock(surface: surface, takenAt: 0, watermark: nil, entries: [])
        stock.entries = entries
        stock.takenAt = Date().timeIntervalSince1970
        stock.watermark = CatalogStockFetch.watermark(from: entries, previous: previous)
        // The run is whole, so the resume mark goes away.
        stock.fetchCursor = nil
        guard persist(stock) else {
            states[surface] = .failed
            return false
        }
        states[surface] = .ready(entries.count)
        Logger.library.notice("STOCK \(surface, privacy: .public) kept \(entries.count) entries")
        // Gutenberg's popularity is not in the dump. It is gathered
        // afterwards, in the background, and NOTHING waits for it.
        if surface == CatalogSource.gutenberg.rawValue {
            Task { await self.gatherGutenbergPopularity() }
        }
        return true
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
        guard let start = store.load(surface: surface) else { return }
        guard start.popularityComplete != true else { return }
        guard await NetworkStatus.isOnWiFi() else { return }
        var page = start.popularityPage ?? 1
        var counts = start.popularity ?? [:]
        while !Task.isCancelled {
            do {
                let answer = try await CatalogStockFetch.gutenbergPopularityPage(page)
                counts.merge(answer.counts) { _, new in new }
                // Read, modify, write per page: a fetch of the same surface
                // may finish between two pages, and a snapshot taken before
                // the loop would carry its old entries, its old stamp and
                // its resume cursor back over the finished run. Then the
                // next start would index the whole collection again.
                guard let current = store.load(surface: surface) else { return }
                let stock = CatalogStockRules.withPopularity(
                    current, counts: counts, nextPage: page + 1, complete: !answer.hasMore)
                guard persist(stock) else { return }
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
