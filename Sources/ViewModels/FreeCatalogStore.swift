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
    static let shared = FreeCatalogStore()
    private init() {}
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
        startLoadIfNeeded()
        return storedRows
    }
    @Published private(set) var storedRows = FreeCatalogLoader.Rows()
    private(set) var loaded = false
    private var gate = CatalogLoadGate()
    /// The network, read in ONE place of this store: four gates asked the
    /// monitor each on their own, now they ask this seat.
    private var isOnline: Bool { NetworkMonitor.shared.isConnected }

    /// Same for the source rows of the merged page.
    var sourceRows: CatalogSourceLoader.SourceRows {
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
        let loaded = await CatalogSourceLoader.load(onRow: { [weak self] apply in
            self?.publish(apply)
        })
        sourcesFailures = loaded.failures
        publish { $0.failures = loaded.failures }
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
        let loadedRows = await FreeCatalogLoader.load()
        // A partial success may NOT book the whole pass as done.
        // Measured shape: one cancelled Jamendo step returned early (silently,
        // and rightly. A cancel is no failure), the other rows filled, and
        // `loaded` then closed the gate for the whole SESSION: no row, no
        // line, no second attempt. `loaded` now means "every ENABLED row has
        // an answer" (content, a stated problem, or the source is off).
        loaded = FreeCatalogLoader.passIsComplete(loadedRows)
        // `loaded == false` alone did NOT reopen the door. The gate
        // still counted the cancelled pass as "attempted", so every later
        // reading surface (Music tab, library) was refused and stayed empty
        // for the whole session. The incomplete pass reopens it, bounded.
        if !loaded {
            gate.reopenForIncompletePass()
            Logger.library.notice("FREECAT pass incomplete — retry allowed (\(self.gate.incompleteRetries)/\(CatalogLoadGate.incompleteRetryLimit))")
        }
        ScrollCalm.run { [weak self] in self?.storedRows = loadedRows }
    }
}
