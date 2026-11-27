// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import SwiftUI
import Combine
import OSLog

/// The ONE shared home of the loaded catalog rows. Home's
/// compute() pass fills it (retry-while-empty stays there); the audiobooks
/// tab row observes the SAME store instead of loading a second time.
@MainActor
final class FreeCatalogStore: ObservableObject {
    /// The app's store: its rows live in their own database
    /// (`CatalogRowStore`), and the first reading fills them from there.
    static let shared = FreeCatalogStore(rowStore: {
        do {
            return try await CatalogRowStore.open()
        } catch {
            Logger.library.error("CATALOG rows not opened, the rows start empty: \(FailureReason.of(error), privacy: .public)")
            return nil
        }
    })

    typealias RowsLoad = @MainActor () async -> FreeCatalogLoader.Rows
    typealias SourcesLoad = @MainActor (CatalogSourceLoader.RowSink?) async -> CatalogSourceLoader.SourceRows

    private let rowStore: @Sendable () async -> CatalogRowStore?
    private let online: @MainActor () -> Bool
    private let loadRows: RowsLoad
    private let loadSources: SourcesLoad
    private let enabledRows: @MainActor () -> Set<FreeCatalogLoader.Rows.Row>

    /// A witness hands in its own database, network, loaders and switches.
    init(rowStore: @escaping @Sendable () async -> CatalogRowStore? = { nil },
         online: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
         loadRows: @escaping RowsLoad = { await FreeCatalogLoader.load() },
         loadSources: @escaping SourcesLoad = { await CatalogSourceLoader.load(onRow: $0) },
         enabledRows: @escaping @MainActor () -> Set<FreeCatalogLoader.Rows.Row> = { CatalogRowKeep.enabled(.live) }) {
        self.rowStore = rowStore
        self.online = online
        self.loadRows = loadRows
        self.loadSources = loadSources
        self.enabledRows = enabledRows
    }

    private var restored = false
    private var restoring: Task<Void, Never>?

    /// The rows the database kept, before any fetch and without a network;
    /// only into rows that are still empty and whose source is on. Once per
    /// store; a missing or unreadable database leaves them empty.
    var hasKeptRows: Bool { false }

    func restore() async {
        if let restoring { return await restoring.value }
        guard !restored else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let rowStore = await self.rowStore() else { return }
            let stored: [CatalogRowStore.Key: [LibraryItem]]
            do {
                stored = try await rowStore.rows()
            } catch {
                Logger.library.error("CATALOG rows not read, the rows start empty: \(FailureReason.of(error), privacy: .public)")
                return
            }
            var rows = self.storedRows
            CatalogRowKeep.restore(stored, into: &rows, enabled: self.enabledRows())
            var sources = self.storedSourceRows
            CatalogRowKeep.restore(stored, into: &sources, allowed: \.isAllowed)
            self.storedRows = rows
            self.storedSourceRows = sources
            Logger.library.notice("CATALOG rows from the database: \(stored.count) rows")
        }
        restoring = task
        await task.value
        restored = true
        restoring = nil
    }

    /// Writes the rows that came whole and notes the ones that failed; a
    /// row that failed keeps what the database holds.
    private func keep(written: [CatalogRowStore.Key: [LibraryItem]], failed: [CatalogRowStore.Key: String]) async {
        guard let rowStore = await rowStore() else { return }
        let now = Date().timeIntervalSince1970 * 1000
        for (key, items) in written {
            do { try await rowStore.replace(key, items: items, atMs: now) } catch {
                Logger.library.error("CATALOG row \(key.rawValue, privacy: .public) not written: \(FailureReason.of(error), privacy: .public)")
            }
        }
        for (key, reason) in failed where written[key] == nil {
            do { try await rowStore.noteFailure(key, reason: reason, atMs: now) } catch {
                Logger.library.error("CATALOG row \(key.rawValue, privacy: .public) failure not noted: \(FailureReason.of(error), privacy: .public)")
            }
        }
    }
    /// Reading and loading cannot be separated: the getter starts the load if
    /// it has not run. A surface that reads the rows without also triggering
    /// the fetch is not expressible any more. That is why the catalogues used
    /// to appear in the music tab only after a visit to Home.
    ///
    /// The trigger asks the gate, which counts ATTEMPTS. See
    /// `CatalogLoadGate` for why an empty pass has to count as one. Asking
    /// whether CONTENT had arrived made every pass that came back empty start
    /// the next one from the next body evaluation: publish, re-render, read,
    /// start. The app kept drawing and stopped reacting to any touch.
    var rows: FreeCatalogLoader.Rows {
        startRestoreIfNeeded()
        startLoadIfNeeded()
        return storedRows
    }
    @Published private(set) var storedRows = FreeCatalogLoader.Rows()
    private(set) var loaded = false
    private var gate = CatalogLoadGate()
    /// The network, read in ONE place of this store: four gates asked the
    /// monitor each on their own, now they ask this seat.
    private var isOnline: Bool { online() }

    /// The first reading fills the rows from the database, once.
    private func startRestoreIfNeeded() {
        guard !restored, restoring == nil else { return }
        Task { await restore() }
    }

    /// Same for the source rows of the merged page.
    var sourceRows: CatalogSourceLoader.SourceRows {
        startRestoreIfNeeded()
        startSourceLoadIfNeeded()
        return storedSourceRows
    }

    private func startLoadIfNeeded() {
        // `loaded` still gates the automatic path: the harness seed fills the
        // rows WITHOUT a pass, and a pass started next to it would publish its
        // empty result over the seeded one.
        guard !loaded,
              gate.startIfNeeded(connected: isOnline) else { return }
        Task { await runLoad() }
    }

    private func startSourceLoadIfNeeded() {
        guard !sourcesLoaded,
              sourcesGate.startIfNeeded(connected: isOnline) else { return }
        Task { await runSourcesLoad() }
    }

    /// Language change ⇒ reload on the next compute pass; the old
    /// rows stay visible until the calm-gated replacement arrives.
    func invalidateForLanguageChange() {
        loaded = false
        sourcesLoaded = false
        gate.reopen()
        sourcesGate.reopen()
    }

    /// The merged page's source rows. Loaded on first open of the
    /// page (NOT in Home's compute pass; five extra network calls do not
    /// belong to app start for a page that may never open this session).
    @Published private(set) var storedSourceRows = CatalogSourceLoader.SourceRows()
    private(set) var sourcesLoaded = false
    private var sourcesGate = CatalogLoadGate()

    /// The error line's tap. Opens a new attempt and loads again.
    func retrySources() async {
        sourcesLoaded = false
        sourcesGate.reopen()
        await ensureSourcesLoaded()
    }

    /// The explicit pass: a page's own task, pull to refresh, the retry above.
    func ensureSourcesLoaded() async {
        guard !sourcesLoaded, isOnline,
              sourcesGate.beginExplicit() else { return }
        await runSourcesLoad()
    }

    /// The page decides its END states from these two. `sourcesLoaded`
    /// alone could not tell "still running" from "ran and found nothing",
    /// and that gap rendered as an eternal spinner (Regel-3-Klasse: a spinner
    /// ends in content, a visible failure, or goes away. Also for an empty
    /// result). Failures publish IMMEDIATELY (tiny value); the heavy rows
    /// stay calm-gated as before.
    @Published private(set) var sourcesLoading = false
    @Published private(set) var sourcesFailures: [CatalogSource: String] = [:]

    /// A row appears AS SOON AS IT IS DONE. Before this
    /// all four were assigned as ONE package, so the slowest source decided
    /// when ANY of them showed. And Gutenberg, which runs last and can lose
    /// against its own timeout, decided it for everybody.
    ///
    /// The calm gate stays (Hitch lesson). It now runs PER ROW instead of
    /// for the whole package. That is the same protection: nothing grows
    /// into a running gesture; it just no longer couples four independent
    /// rows to one moment.
    private func publish(_ apply: @escaping @MainActor (inout CatalogSourceLoader.SourceRows) -> Void) {
        ScrollCalm.run { [weak self] in
            guard let self else { return }
            var rows = self.storedSourceRows
            apply(&rows)
            self.storedSourceRows = rows
            self.sourcesLoaded = !rows.librivoxPopular.isEmpty || !rows.gutenberg.isEmpty
                || !rows.archiveBooks.isEmpty || !rows.oldTimeRadio.isEmpty
        }
    }

    /// The pass itself. One place, whoever started it.
    private func runSourcesLoad() async {
        sourcesLoading = true
        defer { sourcesLoading = false; sourcesGate.finish() }
        await restore()
        let loaded = await loadSources({ [weak self] apply in
            self?.publish(apply)
        })
        sourcesFailures = loaded.failures
        publish { $0.failures = loaded.failures }
        await keep(written: CatalogRowKeep.written(loaded), failed: CatalogRowKeep.failed(loaded))
    }

    #if DEBUG
    /// The harness DELAYS this fill to simulate the late
    /// store arrival the cold start used to miss. Applied through the SAME
    /// calm-gated path as the real loader, so the journey exercises the
    /// exact publish chain (store → observing Home → row appears without a
    /// tab switch).
    func _seedForUITest(classical: [LibraryItem], freeMusic: [LibraryItem]) {
        loaded = true
        var seeded = FreeCatalogLoader.Rows()
        seeded.classical = classical
        seeded.freeMusic = freeMusic
        ScrollCalm.run { [weak self] in self?.storedRows = seeded }
    }
    #endif

    /// The single load pass. Called from compute(), never from a lazily
    /// mounted empty view's own task.
    func ensureLoaded() async {
        guard !loaded, isOnline, gate.beginExplicit() else { return }
        await runLoad()
    }

    private func runLoad() async {
        defer { gate.finish() }
        await restore()
        let fetched = await loadRows()
        // A row that failed or was cancelled keeps what was shown.
        let loadedRows = CatalogRowKeep.merge(previous: storedRows, loaded: fetched, enabled: enabledRows())
        // A partial success may NOT book the whole pass as done.
        // Measured shape: one cancelled Jamendo step returned early (silently,
        // and rightly. A cancel is no failure), the other rows filled, and
        // `loaded` then closed the gate for the whole SESSION: no row, no
        // line, no second attempt. `loaded` now means "every ENABLED row has
        // an answer" (content, a stated problem, or the source is off).
        // Whether this fetch answered every row, not what stands: a kept
        // row must not close the door on a cancelled one.
        loaded = FreeCatalogLoader.passIsComplete(fetched)
        // `loaded == false` alone did NOT reopen the door. The gate
        // still counted the cancelled pass as "attempted", so every later
        // reading surface (Music tab, library) was refused and stayed empty
        // for the whole session. The incomplete pass reopens it, bounded.
        if !loaded {
            gate.reopenForIncompletePass()
            Logger.library.notice("FREECAT pass incomplete — retry allowed (\(self.gate.incompleteRetries)/\(CatalogLoadGate.incompleteRetryLimit))")
        }
        ScrollCalm.run { [weak self] in self?.storedRows = loadedRows }
        await keep(written: CatalogRowKeep.written(fetched), failed: CatalogRowKeep.failed(fetched))
    }
}
