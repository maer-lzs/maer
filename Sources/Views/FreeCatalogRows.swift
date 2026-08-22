// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// 0714d26: the free-catalog Discover rows on Home — "New free audiobooks"
/// (LibriVox, keyless) · "Popular free audiobooks" (archive.org downloads
/// sort, keyless) · "Free music" (Jamendo, only with a client key). Tiles
/// play DIRECTLY (tap-to-play like radio); the context menu opens the
/// license/details sheet (public-domain badge resp. the Jamendo ToS
/// attribution with artist + backlink). Each row has its own opt-out on the
/// network-services page; rows are net-gated and hide silently when empty.
struct FreeCatalogRows: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// 34c36e1: the rows are DUMB now — a lazily-mounted, initially EMPTY
    /// view below the fold never ran its .task reliably (the third suspect);
    /// loading lives in HomeView's compute() pass (always runs, calm-gated)
    /// via `FreeCatalogLoader`.
    /// Auftrag L1: ONE mixed "Entdecken · Musik" row replaced the two source
    /// rows (classical + Jamendo) — interleaved, not two blocks (the archive-
    /// row mix decision), through the ONE merge (`HomeSections.interleave`).
    /// The source gates keep acting through the LOADER (a gated-off source
    /// loads nothing, so its share is simply absent); both empty → no row.
    /// The entry chevron opens the small music-catalog page (I2 earlier).
    let freeMusic: [LibraryItem]
    let classical: [LibraryItem]
    @State private var detailItem: LibraryItem?

    var body: some View {
        Group {
            if !classical.isEmpty || !freeMusic.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Discover · Music",
                                     destination: MusicRoute.freeCatalogArea)
                        .accessibilityIdentifier("home-discover-music")
                    tileRow(items: HomeSections.interleave([classical, freeMusic],
                                                           limit: RowPreview.limit))
                }
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func tileRow(items: [LibraryItem]) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        // 174f855 Tap-Konvention: catalog tiles are class
                        // NACHSCHLAGEN — the tap answers "what is that?", the
                        // sheet's prominent Play answers "hear it" one tap
                        // later. Long-press keeps Play as the shortcut.
                        FreeCatalogBookTile(
                            item: item,
                            placeholderSystemImage: item.id.hasPrefix(FreeCatalog.jamendoPrefix)
                                ? "music.note" : "book.closed",
                            onTap: { detailItem = item }
                        )
                        .cardRowSlot(spacing: 14)
                        .contextMenu {
                            Button {
                                Task { await playerCoordinator.open(item: item) }
                            } label: { Label("Play", systemImage: "play.fill") }
                            Button {
                                detailItem = item
                            } label: { Label("Details", systemImage: "info.circle") }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
    }
}

/// fbcff9f: the LibriVox import shows its progress where every other
/// download does — in the tile's corner slot, through the SHARED
/// `UnifiedDownloadRing`. Self-observing like `CardDownloadBadge`, so only
/// this small view re-renders per progress tick; nothing at all is drawn
/// while no import runs for THIS item (the corner slot collapses).
struct FreeCatalogImportBadge: View {
    let itemId: String
    @ObservedObject private var importer = LibriVoxImporter.shared
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    var body: some View {
        if importer.activeBookId == itemId,
           let fraction = LibriVoxImporter.ringFraction(importer.phase) {
            Button { importer.cancel() } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                        .frame(width: ringSize + 10, height: ringSize + 10)
                    UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                        .frame(width: ringSize, height: ringSize)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        }
    }
}

/// 34c36e1: the ONE loader — called from HomeView.compute() (always runs,
/// no lazy-mount dependency). WireCorpus discipline at the call sites: a
/// throwing client is CAUGHT and LOGGED with the actual error (never a
/// silent try?-collapse to empty); the per-row log line names loaded/
/// filtered counts and the reason when a row stays empty.
@MainActor
enum FreeCatalogLoader {
    struct Rows {
        /// 7edb21b: LibriVox books for the DISCOVER mix (moderate share).
        var discoverBooks: [LibraryItem] = []
        /// cb99bf6: the audiobooks-tab tile row (same fetch, wider cut).
        var tabBooks: [LibraryItem] = []
        var freeMusic: [LibraryItem] = []
        var classical: [LibraryItem] = []
        /// Netlabels (archive.org, CC) — its own row next to Jamendo; the
        /// source name at the heading keeps them apart (Auftrag Punkt 4).
        var netlabels: [LibraryItem] = []
    }

    /// Moderate share (Fortsetzen-Deckel-Denke): at most this many LibriVox
    /// tiles mix into Discover; constant, not a setting.
    static let discoverBookCap = 3

    /// 🟡 P10-Nachfassung: THE entry point for curated PREVIEW picks. Every
    /// surface that shows a small number of archive.org picks goes through
    /// here — the first version probed only the audiobook picks, and the
    /// sibling surface ("Discover · Music") kept showing fresh ghost records.
    /// Fourth instance of "the rule was built where it was reported".
    ///
    /// **The boundary, deliberately:** curated PREVIEW yes, mass no. Full
    /// grids and pages keep loading unprobed (dozens of requests per visit)
    /// — there the reactive marking heals, which is why a ghost record
    /// disappears there after the first tap.
    static func picks(_ docs: [ArchivePopularDoc], cap: Int,
                      provider: FreeCatalogProvider) async -> [LibraryItem] {
        await livePicks(from: docs.compactMap { provider.remember(popular: $0) }, cap: cap)
    }

    /// Take the first `cap` items that are still ALIVE — probing forward
    /// through the list, so a withdrawn record is replaced rather than
    /// leaving a gap. `unknown` (service down) counts as usable: a network
    /// failure must not empty the row (a throw is not an end).
    static func livePicks(from items: [LibraryItem], cap: Int) async -> [LibraryItem] {
        var out: [LibraryItem] = []
        // 🟢 Q10a: a pick whose COVER does not load right now is not dead —
        // the thumbnail service answers 504 for perfectly healthy items. Such
        // a pick is DEFERRED, not dropped: the next candidate moves up, and
        // it comes back at the end if the row still has room. Nothing is
        // remembered about it (a service failure is never a finding).
        var deferred: [LibraryItem] = []
        for item in items {
            guard out.count < cap else { break }
            guard item.id.hasPrefix(FreeCatalog.archivePrefix) else {
                out.append(item)
                continue
            }
            let identifier = String(item.id.dropFirst(FreeCatalog.archivePrefix.count))
            let liveness = await ArchiveOrgClient.liveness(identifier: identifier)
            DeadCatalogItems.note(liveness, for: identifier)
            guard liveness != .dead else { continue }
            if await coverLoads(for: item) { out.append(item) } else { deferred.append(item) }
        }
        // If every cover is stuck the row shows placeholders — honestly, and
        // never emptier than before (a service outage must not blank it).
        for item in deferred where out.count < cap { out.append(item) }
        return out
    }

    /// Cheap cover probe for a PICK: does the thumbnail answer at all? A 5xx
    /// or a transport failure answers false and is not written down anywhere.
    private static func coverLoads(for item: LibraryItem) async -> Bool {
        guard let url = FreeCatalogProvider.shared.coverURL(forItemId: item.id) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.maer.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    static func load() async -> Rows {
        // 5034add: master off ⇒ nothing loads, nothing fetches — the whole
        // catalog feature is dark (UI gates hide the surfaces separately).
        guard AppStorageKeys.freeCatalogsMasterActive else {
            return Rows()
        }
        var rows = Rows()
        #if DEBUG
        if UITestSeed.isActive { return rows }   // no external calls in the harness
        #endif
        let provider = FreeCatalogProvider.shared
        let librivoxOn = AppStorageKeys.librivoxActive
        let archiveOn = AppStorageKeys.archiveBooksActive
        let jamendoOn = AppStorageKeys.jamendoActive

        let areaOn = AppStorageKeys.freeAudiobooksAreaActive
        if librivoxOn && areaOn {
            do {
                // 938aebc: the row used to fetch LibriVox's SINCE feed (new
                // additions) — which is why it showed obscure newcomers and
                // never the classics. It now rides the downloads sort, one
                // query PER active language, interleaved.
                let codes = SuggestionLanguages.current()
                let docs = try await ArchiveOrgClient.popularLibriVoxByLanguage(
                    rowsPerLanguage: 12, languageCodes: codes, limit: 12)
                Logger.library.notice("FREECAT discover-books sort=downloads codes=\(codes.isEmpty ? "-" : codes.joined(separator: ","), privacy: .public) loaded=\(docs.count)")
                if docs.isEmpty {
                    Logger.library.notice("FREECAT discover-books EMPTY: no docs for the active languages")
                }
                // 🟡 P10: the shown picks go through the ONE probed entry
                // point; the tab row is the same fetch, second cut (cb99bf6)
                // and stays unprobed — it is the wider list, not a preview.
                rows.discoverBooks = await Self.picks(docs, cap: Self.discoverBookCap,
                                                      provider: provider)
                rows.tabBooks = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                Logger.library.error("FREECAT discover-books FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        let classicalOn = (AppStorageKeys.freeClassicalActive) && archiveOn
        if classicalOn {
            do {
                // Tages-Rotation: die Reihe zeigt heute eine ANDERE Seite des
                // Beliebtheits-Fensters als gestern (die All-Zeiten-Bestenliste
                // aendert sich sonst nie).
                let page = CatalogRotation.page(
                    total: ArchiveMusicCatalog.classical.measuredTotal, rowSize: 12, on: Date())
                let docs = try await ArchiveOrgClient.popularMusic(
                    area: ArchiveMusicCatalog.classical, rows: 12, page: page)
                Logger.library.notice("FREECAT classical-teaser loaded=\(docs.count)")
                rows.classical = await Self.picks(docs, cap: RowPreview.limit, provider: provider)
            } catch {
                Logger.library.error("FREECAT classical-teaser FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        let netlabelsOn = (AppStorageKeys.netlabelsActive) && archiveOn
        if netlabelsOn {
            do {
                let page = CatalogRotation.page(
                    total: ArchiveMusicCatalog.netlabels.measuredTotal, rowSize: 12, on: Date())
                let docs = try await ArchiveOrgClient.popularMusic(
                    area: ArchiveMusicCatalog.netlabels, rows: 12, page: page)
                Logger.library.notice("FREECAT netlabels loaded=\(docs.count)")
                rows.netlabels = await Self.picks(docs, cap: RowPreview.limit, provider: provider)
            } catch {
                Logger.library.error("FREECAT netlabels FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        if jamendoOn {
            if JamendoClient.clientId() == nil {
                Logger.library.notice("FREECAT jamendo EMPTY: no client key")
            } else {
                do {
                    // Jamendo kennt KEINE Zufalls-Sortierung (gemessen:
                    // `order=random` antwortet mit status=failed), also
                    // dieselbe Tages-Rotation ueber den seit P8 vorhandenen
                    // `offset`. Fenster bewusst gesetzt statt gemessen: die
                    // Beliebtheits-Spitze ist bei Jamendo ueber Wochen-,
                    // Monats- und Download-Sortierung IDENTISCH (gemessen),
                    // die oberen ~600 Titel sind das brauchbare Feld.
                    let jamendoPage = CatalogRotation.page(total: 6_000, rowSize: 12, on: Date())
                    let tracks = try await JamendoClient.popularTracks(
                        limit: 12, offset: (jamendoPage - 1) * 12)
                    Logger.library.notice("FREECAT jamendo loaded=\(tracks.count)")
                    rows.freeMusic = tracks.compactMap { provider.remember(track: $0) }
                } catch {
                    Logger.library.error("FREECAT jamendo FAILED: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return rows
    }
}

/// Paket 1 (11be262): the load layer of the MERGED catalog page — one pass,
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
        /// 0b72ac4 A1/A3: failed sources WITH the short reason (log + error
        /// line). Cancellations never land here — a cancelled task is "not
        /// loaded yet", not a broken source.
        var failures: [CatalogSource: String] = [:]
    }

    /// Wraps one fetch as a Result so the error ARRIVES as an error —
    /// `try?` under `async let` ate the distinction cancellation vs. failure,
    /// which booked a torn-down .task as four broken sources at once (0b72ac4).
    private static func fetched<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) } catch { return .failure(error) }
    }

    /// Unwraps one source result: success returns the value, cancellation
    /// stays silent (A1), a real failure books source + reason (A3).
    private static func value<T>(_ result: Result<T, Error>, _ source: CatalogSource,
                                 failures: inout [CatalogSource: String]) -> T? {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            if let reason = FreeCatalog.failureReason(error) {
                failures[source] = reason
            }
            return nil
        }
    }

    static func load() async -> SourceRows {
        guard AppStorageKeys.freeCatalogsMasterActive else {
            return SourceRows()
        }
        var rows = SourceRows()
        #if DEBUG
        if UITestSeed.isActive { return rows }
        #endif
        let provider = FreeCatalogProvider.shared
        let codes = SuggestionLanguages.current()
        let librivoxOn = AppStorageKeys.librivoxActive
        let archiveOn = AppStorageKeys.archiveBooksActive

        // Tages-Rotation der BELIEBTHEITS-Reihen (Auftrag 09.08.): dieselbe
        // Sortierung, aber taeglich eine andere Seite des oberen Zehntels.
        // „Neu bei LibriVox" rotiert NICHT — die Reihe ist per Definition
        // schon taeglich frisch (sie sortiert nach Datum).
        // Bestaende gemessen 09.08.: LibriVox 21.711 · IA-Hoerbuecher 4.257 ·
        // OTR (lizenziert) 2.309.
        let today = Date()
        let lvPage = CatalogRotation.page(total: 21_711, rowSize: 12, on: today)
        let iaPage = CatalogRotation.page(total: 4_257, rowSize: 12, on: today)
        let otrPage = CatalogRotation.page(total: 2_309, rowSize: 12, on: today)

        // ONE pass, sources concurrent; each error arrives AS an error.
        async let newTask = fetched { try await LibriVoxClient.newBooks(sinceDays: 120, limit: 40) }
        async let popularTask = fetched { try await ArchiveOrgClient.popularLibriVoxByLanguage(
            rowsPerLanguage: 12, languageCodes: codes, limit: 12, page: lvPage) }
        async let archiveTask = fetched { try await ArchiveOrgClient.audiobooksOutsideLibriVox(
            rows: 12, languageCodes: codes, page: iaPage).docs }
        async let otrTask = fetched { try await ArchiveOrgClient.popularOldTimeRadio(
            rows: 12, page: otrPage) }

        if librivoxOn {
            if let books = value(await newTask, .librivox, failures: &rows.failures) {
                let filtered = FreeCatalog.filterByLanguages(books, codes: codes)
                rows.librivoxNew = filtered.prefix(RowPreview.limit).map { provider.remember(book: $0) }
            }
            if let docs = value(await popularTask, .librivox, failures: &rows.failures) {
                rows.librivoxPopular = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
            }
        } else { _ = await newTask; _ = await popularTask }
        if archiveOn {
            if let docs = value(await archiveTask, .archiveBooks, failures: &rows.failures) {
                rows.archiveBooks = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
            }
            if codes.contains("en") {
                if let docs = value(await otrTask, .oldTimeRadio, failures: &rows.failures) {
                    rows.oldTimeRadio = await FreeCatalogLoader.picks(docs, cap: RowPreview.limit, provider: provider)
                }
            } else { _ = await otrTask }
        } else { _ = await archiveTask; _ = await otrTask }
        // Gutenberg last (sequential): own fallback ladder, polite rate limit.
        if librivoxOn {
            let gut = await fetched { () -> [GutenbergClient.Book] in
                var books: [GutenbergClient.Book] = []
                for page in 1...2 {
                    let hit = try await GutenbergClient.audiobooks(languages: codes, page: page)
                    books += hit
                    if hit.isEmpty { break }
                }
                if books.isEmpty, !codes.isEmpty {
                    books = try await GutenbergClient.audiobooks(languages: [], page: 1)
                }
                return books
            }
            if let books = value(gut, .gutenberg, failures: &rows.failures) {
                rows.gutenberg = books.compactMap { provider.remember(gutenberg: $0) }
            }
        }
        for (source, reason) in rows.failures {
            // A3: reason is short and URL-free by construction (failureReason).
            Logger.library.error("FREECAT source=\(source.rawValue, privacy: .public) FAILED: \(reason, privacy: .public)")
        }
        Logger.library.notice("FREECAT sources lvNew=\(rows.librivoxNew.count) lvPop=\(rows.librivoxPopular.count) ia=\(rows.archiveBooks.count) gut=\(rows.gutenberg.count) otr=\(rows.oldTimeRadio.count)")
        return rows
    }
}

/// cb99bf6: the ONE shared home of the loaded catalog rows — Home's
/// compute() pass fills it (retry-while-empty stays there); the audiobooks
/// tab row observes the SAME store instead of loading a second time.
@MainActor
final class FreeCatalogStore: ObservableObject {
    static let shared = FreeCatalogStore()
    private init() {}
    /// Reading and loading cannot be separated: the getter starts the load if
    /// it has not run. A surface that reads the rows without also triggering
    /// the fetch is not expressible any more — that is why the catalogues used
    /// to appear in the music tab only after a visit to Home.
    ///
    /// The trigger asks the gate, which counts ATTEMPTS — see
    /// `CatalogLoadGate` for why an empty pass has to count as one. Asking
    /// whether CONTENT had arrived made every pass that came back empty start
    /// the next one from the next body evaluation: publish, re-render, read,
    /// start — the app kept drawing and stopped reacting to any touch.
    var rows: FreeCatalogLoader.Rows {
        startLoadIfNeeded()
        return storedRows
    }
    @Published private(set) var storedRows = FreeCatalogLoader.Rows()
    private(set) var loaded = false
    private var gate = CatalogLoadGate()

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
              gate.startIfNeeded(connected: NetworkMonitor.shared.isConnected) else { return }
        Task { await runLoad() }
    }

    private func startSourceLoadIfNeeded() {
        guard !sourcesLoaded,
              sourcesGate.startIfNeeded(connected: NetworkMonitor.shared.isConnected) else { return }
        Task { await runSourcesLoad() }
    }

    /// 784aceb: language change ⇒ reload on the next compute pass; the old
    /// rows stay visible until the calm-gated replacement arrives.
    func invalidateForLanguageChange() {
        loaded = false
        sourcesLoaded = false
        gate.reopen()
        sourcesGate.reopen()
    }

    /// Paket 1: the merged page's source rows — loaded on first open of the
    /// page (NOT in Home's compute pass; five extra network calls do not
    /// belong to app start for a page that may never open this session).
    @Published private(set) var storedSourceRows = CatalogSourceLoader.SourceRows()
    private(set) var sourcesLoaded = false
    private var sourcesGate = CatalogLoadGate()

    /// A2: the error line's tap — opens a new attempt and loads again.
    func retrySources() async {
        sourcesLoaded = false
        sourcesGate.reopen()
        await ensureSourcesLoaded()
    }

    /// The explicit pass: a page's own task, pull to refresh, the retry above.
    func ensureSourcesLoaded() async {
        guard !sourcesLoaded, NetworkMonitor.shared.isConnected,
              sourcesGate.beginExplicit() else { return }
        await runSourcesLoad()
    }

    /// R29: the page decides its END states from these two — `sourcesLoaded`
    /// alone could not tell "still running" from "ran and found nothing",
    /// and that gap rendered as an eternal spinner (Regel-3-Klasse: a spinner
    /// ends in content, a visible failure, or goes away — also for an empty
    /// result). Failures publish IMMEDIATELY (tiny value); the heavy rows
    /// stay calm-gated as before.
    @Published private(set) var sourcesLoading = false
    @Published private(set) var sourcesFailures: [CatalogSource: String] = [:]

    /// The pass itself — one place, whoever started it.
    private func runSourcesLoad() async {
        sourcesLoading = true
        defer { sourcesLoading = false; sourcesGate.finish() }
        let loaded = await CatalogSourceLoader.load()
        sourcesLoaded = !loaded.librivoxPopular.isEmpty || !loaded.gutenberg.isEmpty
            || !loaded.archiveBooks.isEmpty || !loaded.oldTimeRadio.isEmpty
        sourcesFailures = loaded.failures
        BottomBarState.shared.runWhenCalm { [weak self] in self?.storedSourceRows = loaded }
    }

    #if DEBUG
    /// Befund-V journey: the harness DELAYS this fill to simulate the late
    /// store arrival the cold start used to miss — applied through the SAME
    /// calm-gated path as the real loader, so the journey exercises the
    /// exact publish chain (store → observing Home → row appears without a
    /// tab switch).
    func _seedForUITest(classical: [LibraryItem], freeMusic: [LibraryItem]) {
        loaded = true
        var seeded = FreeCatalogLoader.Rows()
        seeded.classical = classical
        seeded.freeMusic = freeMusic
        BottomBarState.shared.runWhenCalm { [weak self] in self?.storedRows = seeded }
    }
    #endif

    /// The single load pass (34c36e1 discipline: called from compute(),
    /// never from a lazily mounted empty view's own task).
    func ensureLoaded() async {
        guard !loaded, NetworkMonitor.shared.isConnected, gate.beginExplicit() else { return }
        await runLoad()
    }

    private func runLoad() async {
        defer { gate.finish() }
        let loadedRows = await FreeCatalogLoader.load()
        loaded = !loadedRows.discoverBooks.isEmpty
            || !loadedRows.freeMusic.isEmpty || !loadedRows.classical.isEmpty || !loadedRows.netlabels.isEmpty
        BottomBarState.shared.runWhenCalm { [weak self] in self?.storedRows = loadedRows }
    }
}

/// License/details sheet: public-domain badge for LibriVox/archive items;
/// Jamendo carries the ToS-mandated artist credit, "via Jamendo" and the
/// DIRECT backlink to the track page.
struct FreeCatalogDetailSheet: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    /// 3125a42: take-into-library state (ABS upload / local feed).
    @ObservedObject private var importer = LibriVoxImporter.shared
    @State private var absLibraries: [ABSLibrary] = []
    @State private var showLibraryPicker = false
    @State private var showWiFiWarning = false
    @State private var localSubscribed = false
    /// b395e5f: hi-res cover once resolved (thumb → hires upgrade).
    @State private var hiresCover: URL?
    /// P2: the metadata API's item description (archive items resolve it
    /// lazily from the SAME metadata endpoint the detail path uses — no new
    /// API); collapsed after a few lines like the book descriptions.
    @State private var itemDescription: String?
    @State private var descriptionExpanded = false

    private var isJamendo: Bool { item.id.hasPrefix(FreeCatalog.jamendoPrefix) }
    private var jamendoTrack: JamendoTrack? {
        FreeCatalogProvider.shared.jamendoTrack(forId: item.id)
    }
    private var librivoxURL: URL? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)?.url_librivox.flatMap { URL(string: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // b395e5f: thumb first, hi-res swapped in once resolved
                // (soft crossfade; ImageCache persists both).
                CachedAsyncImage(url: hiresCover ?? AppSession.shared.coverURL(forItemId: item.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: isJamendo ? "music.note" : "book.closed")
                            .font(.largeTitle).foregroundStyle(.secondary))
                }
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .animation(.easeInOut(duration: 0.25), value: hiresCover)

                VStack(spacing: 4) {
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                    if let author = item.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if isJamendo {
                    // ToS: artist credit + provider credit + direct backlink.
                    VStack(spacing: 6) {
                        Label("Creative Commons — via Jamendo", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let share = jamendoTrack?.shareurl.flatMap({ URL(string: $0) }) {
                            Link(destination: share) {
                                Label("View on Jamendo", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        // e948444: do not claim public domain for everything —
                        // an Old-Time-Radio item can be CC-BY-NC-ND, and the
                        // user should see WHICH licence, not a blanket badge.
                        if let licence = FreeCatalogProvider.shared.licence(forItemId: item.id) {
                            Label(licence, systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // 50aefa8/12753d8: the else branch USED to claim
                            // public domain for every title without a licence
                            // field — 4271 of them in the classical row.
                            //
                            // The claim is gone, and so is the seal: a
                            // checkmark IS an assertion. What replaces it
                            // depends on what the source actually tells us
                            // (pure FreeCatalog.rightsNote).
                            switch FreeCatalog.rightsNote(
                                year: item.media?.metadata?.publishedYear?.value) {
                            case .publicDomain:
                                // ≤ 1925: expired even under the LONGEST of the
                                // three terms, so it holds everywhere.
                                Label("Public domain", systemImage: "checkmark.seal")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .termsApply(let year):
                                // A fact about TERMS, never a verdict about
                                // this title — the answer differs by country,
                                // and the device region is not the listener's
                                // jurisdiction (travel, foreign account, VPN).
                                Label(String(localized: "Recording from \(year). Sound recordings are free after 50 years in Switzerland, 70 in the EU and 100 in the USA."),
                                      systemImage: "clock")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .unknown:
                                Label("Rights status not stated by the source",
                                      systemImage: "questionmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        // P2: the item description, below the rights capsule —
                        // HTML remnants cleaned by the ONE existing text
                        // preparation (podcastPlainText, Regel 2); collapsed
                        // after four lines, tap expands.
                        if let itemDescription, !itemDescription.isEmpty {
                            Text(podcastPlainText(itemDescription))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(descriptionExpanded ? nil : 4)
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture { descriptionExpanded.toggle() }
                        }
                        if let url = librivoxURL {
                            Link(destination: url) {
                                Label("View on LibriVox", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        } else if item.id.hasPrefix(FreeCatalog.archivePrefix),
                                  let url = URL(string: "https://archive.org/details/\(item.id.dropFirst(FreeCatalog.archivePrefix.count))") {
                            Link(destination: url) {
                                Label("View on Internet Archive", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Button {
                    dismiss()
                    Task { await playerCoordinator.open(item: item) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                // 3125a42: take a LibriVox book into the library — ABS upload
                // (only with a connected audiobook library) or a LOCAL feed
                // subscription (clearly labeled: no server sync).
                if item.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                    importSection
                }
                Spacer(minLength: 0)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if item.id.hasPrefix(FreeCatalog.librivoxPrefix) {
                hiresCover = await FreeCatalogProvider.shared.hiresCoverURL(forItemId: item.id)
                absLibraries = await LibriVoxImporter.audiobookLibraries()
            }
            // P2: the description reaches the sheet. Known metadata first
            // (LibriVox/Gutenberg rows carry it); archive items ask the ONE
            // metadata endpoint (same call class as runtime/hi-res).
            itemDescription = item.media?.metadata?.description
            if itemDescription == nil, item.id.hasPrefix(FreeCatalog.archivePrefix) {
                let identifier = String(item.id.dropFirst(FreeCatalog.archivePrefix.count))
                let meta = try? await ArchiveOrgClient.metadata(identifier: identifier)
                itemDescription = meta?.metadata?.description?.joined
            }
        }
        // Library picker (first use / vanished remembered target). The
        // choice is remembered; the folder is the library's first (ABS
        // libraries practically always carry exactly one).
        .confirmationDialog("Choose the target library", isPresented: $showLibraryPicker,
                            titleVisibility: .visible) {
            ForEach(absLibraries) { library in
                Button(library.name) {
                    Task {
                        var folderId = library.folders?.first?.id
                        if folderId == nil {
                            folderId = (try? await AppSession.shared.apiClient
                                .fetchLibraryFolders(libraryId: library.id))?.first?.id
                        }
                        guard let folderId else { return }
                        UserDefaults.standard.set(library.id, forKey: AppStorageKeys.librivoxImportLibraryId)
                        UserDefaults.standard.set(folderId, forKey: AppStorageKeys.librivoxImportFolderId)
                        begin(libraryId: library.id, folderId: folderId)
                    }
                }
            }
        }
        .alert("Not on Wi-Fi", isPresented: $showWiFiWarning) {
            Button("Continue on Cellular", role: .destructive) {
                Task { await pickLibraryAndStart() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audiobooks are large (often several hundred MB). Continue on cellular data?")
        }
    }

    private var book: LibriVoxBook? {
        FreeCatalogProvider.shared.librivoxBook(forId: item.id)
    }

    @ViewBuilder
    private var importSection: some View {
        switch importer.phase {
        case .downloading(let section, let of) where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                // fbcff9f: the detail shows the SAME ring as the tile (one
                // progress language), the part line stays as the detail text.
                UnifiedDownloadRing(fraction: LibriVoxImporter.ringFraction(importer.phase) ?? -1,
                                    lineWidth: 3, tint: .accentColor)
                    .frame(width: 34, height: 34)
                Text("Downloading part \(section) of \(of)…")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { importer.cancel() }
                    .font(.caption)
            }
        case .uploading where importer.activeBookId == item.id:
            VStack(spacing: 6) {
                ProgressView()
                Text("Uploading to your server…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        // 31974ef (3): terminal states belong to THEIR book only — a
        // foreign sheet falls through to the menu below.
        case .done where importer.activeBookId == item.id:
            Label("Added to your library.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .duplicate(let existing) where importer.activeBookId == item.id:
            Label("Already in that library: \(existing)", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message) where importer.activeBookId == item.id:
            // 31974ef (2): the retry path — back to the menu on demand.
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try Again") { importer.reset() }
                    .font(.caption)
            }
        default:
            if importer.busy {
                // A second import while one runs: clear refusal, no ghost UI.
                Label("Another import is already running.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Menu {
                if !absLibraries.isEmpty {
                    Button {
                        startServerImport()
                    } label: {
                        Label("To my server (Audiobookshelf)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                if book?.url_rss?.isEmpty == false {
                    Button {
                        subscribeLocally()
                    } label: {
                        Label("Subscribe as feed (local only)", systemImage: "dot.radiowaves.up.forward")
                    }
                }
            } label: {
                Label(localSubscribed ? "Subscribed locally — no server sync" : "Add to Library…",
                      systemImage: localSubscribed ? "checkmark.circle" : "plus.circle")
                    .font(.subheadline)
            }
            .disabled(localSubscribed)
            .accessibilityIdentifier("librivox-import-menu")
            }
        }
    }

    private func startServerImport() {
        // Wi-Fi gate (books run 100–500 MB) — the existing cellular warning
        // mechanism; explicit confirmation continues on cellular.
        let warn = AppStorageKeys.warnCellularDownloadValue
        Task {
            if warn, !(await NetworkStatus.isOnWiFi()) {
                showWiFiWarning = true
            } else {
                await pickLibraryAndStart()
            }
        }
    }

    private func pickLibraryAndStart() async {
        // Remembered target; picker on first use (or when it vanished).
        let storedLib = UserDefaults.standard.string(forKey: AppStorageKeys.librivoxImportLibraryId)
        if let storedLib, absLibraries.contains(where: { $0.id == storedLib }),
           let folder = UserDefaults.standard.string(forKey: AppStorageKeys.librivoxImportFolderId) {
            begin(libraryId: storedLib, folderId: folder)
        } else {
            showLibraryPicker = true
        }
    }

    private func begin(libraryId: String, folderId: String) {
        guard let book else { return }
        LibriVoxImporter.shared.start(book: book, itemId: item.id,
                                      libraryId: libraryId, folderId: folderId)
    }

    private func subscribeLocally() {
        guard let rss = book?.url_rss, !rss.isEmpty else { return }
        Task {
            localSubscribed = await PodcastSubscriptions.shared.subscribe(urlString: rss)
        }
    }
}
