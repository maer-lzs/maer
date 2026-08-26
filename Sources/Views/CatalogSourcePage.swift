// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE one parameterised source page. Every catalog row's chevron lands
/// here. Fundgrube with staged paging (the page IS the target surface, so no
/// preview cap), ordered by the axis that CARRIES for this source:
///
///   LibriVox / Gutenberg → genre chips (ONE axis. The LCSH spellings
///     extend `CatalogGenreAxis`, no second axis next to it)
///   Internet Archive → NO chips (subjects are collection boilerplate,
///     measured: "livres audio gratuits", "mp3", "learn french")
///   Old Time Radio → no chips (series bundles are the unit)
///   Feed sources → the curated rows, complete (no paging. The stock IS the
///     curation)
///
/// Only shelves the LOADED stock fills appear. An empty chip
/// is an affordance without a target.
struct CatalogSourcePage: View {
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared

    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    /// Language-fallback as SESSION state (one truth, held here).
    @State private var languageFallback = false
    @State private var detailItem: LibraryItem?
    /// What a shelf ACTUALLY has, asked at the source. Before this the
    /// page classified a randomly loaded pool itself, so "Horror" stood there
    /// with one tile while the source held 102. The surface answered
    /// what happened to be loaded where the heading asks how much there is.
    @State private var shelfStock: [String: (items: [LibraryItem], total: Int?)] = [:]
    @State private var shelvesLoaded = false
    @State private var shelvesLoading = false
    /// Why paging stopped. A failure is not exhaustion and gets a way back.
    @State private var pageFailure: String?
    /// Which shelves could not be ASKED. Kept apart from a source that has
    /// nothing here, which looks identical on the surface but is not.
    @State private var shelfFailures: [String: String] = [:]
    /// Which shelves the stored day says this source HAS. Read once
    /// when the page opens, so the warm visit can draw exactly those.
    @State private var knownShelfKeys: Set<String> = []
    /// The stock per DECADE. Old Time Radio only, where time is the more
    /// natural division than genre.
    @State private var decadeStock: [String: (items: [LibraryItem], total: Int?)] = [:]

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    /// Chips only where the axis carries (measured per source). The genre
    /// scaffolding covers the measured sources. LibriVox, Gutenberg, IA
    /// audiobooks (26 % shelve) and OTR (40 % shelve).
    /// A surface promises shelves only where a query actually backs them.
    /// The old list named four sources by hand while the loader could serve
    /// two. So LibriVox and Gutenberg promised shelves and showed none.
    private var hasChips: Bool { CatalogShelfSource.canServeShelves(source) }

    private func genres(of item: LibraryItem) -> [String] {
        item.media?.metadata?.genres ?? []
    }

    /// Which shelves the loaded stock fills. Via the source's OWN spelling
    /// family (LibriVox genre names vs. Gutenberg LCSH subjects).
    /// A shelf appears because the SOURCE has it, not because the
    /// loaded pool happened to contain one of its titles. G8 still holds.
    /// A shelf whose stock is empty does not appear at all.
    private var shelves: [(key: String, title: String)] {
        guard hasChips else { return [] }
        return CatalogGenreAxis.librivoxShelves.filter { shelf in
            !(shelfStock[shelf.key]?.items.isEmpty ?? true)
        }
    }

    /// Against the layout shift: the shelf rows in browse order, each one
    /// either FILLED or a placeholder.
    ///
    /// A warm visit knows from the day store exactly which shelves exist.
    /// They stand there at once and fill IN PLACE. Nothing jumps, and a shelf
    /// the source does not have never appears. A cold visit knows nothing and
    /// gets the ONE named block further down instead.
    private var shelfSlots: [(key: String, title: String, ready: Bool)] {
        guard hasChips else { return [] }
        return CatalogGenreAxis.librivoxShelves.compactMap { shelf in
            if shelfStock[shelf.key]?.items.isEmpty == false {
                return (shelf.key, shelf.title, true)
            }
            if !shelvesLoaded, knownShelfKeys.contains(shelf.key) {
                return (shelf.key, shelf.title, false)
            }
            return nil
        }
    }

    /// The cold first visit: ONE named block instead of eighteen separate
    /// insertions. It hangs on the MEASURED wait, not on the source name. For
    /// archive.org the cold case is under a second, and a skeleton for that
    /// would be worse than none.
    private var showsShelfPlaceholder: Bool {
        hasChips && !shelvesLoaded && knownShelfKeys.isEmpty
            && CatalogShelfSource.showsLoadingPlaceholder(source)
    }

    /// This page's LibriVox items are archive.org documents
    /// (`librivoxPopular` → `remember(popular:)`), so they carry archive
    /// SUBJECTS. Not LibriVox genre names. Reading them through the LibriVox
    /// genre axis matched a part of them by luck. Measured over the 120 most
    /// downloaded `librivoxaudio` entries: the genre axis placed 40, the
    /// subject axis places 58. The books that DO speak LibriVox genres stand
    /// in the newest-first row and never come through here.
    private func shelvesOf(_ item: LibraryItem) -> [String] {
        CatalogGenreAxis.shelves(forSubjects: genres(of: item))
    }

    var body: some View {
        ScrollView {
            if source.isFeedBased {
                feedList
            } else {
                catalogGrid
            }
        }
        .navigationTitle(Text(verbatim: source.title))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task {
            knownShelfKeys = CatalogShelfSource.knownShelfKeys(for: source)
            async let shelvesTask: Void = loadShelves()
            if items.isEmpty {
                // Seed from the overview's already-loaded preview so the page
                // opens filled, then page onward from the network.
                items = seedItems()
                await load()
            }
            await shelvesTask
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// E-Rest: a feed source is a TILE GRID too. The list form
    /// belongs to search; that the curation IS the full stock answers the
    /// chevron question, not the FORM question (blueprint pages are grids).
    /// Same tile as every catalog-show surface (show-preview tap + subscribe
    /// badge); `CatalogFeedRow` died with this, its last call site.
    private var feedList: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(OERRLiveStore.feeds(for: source, languages: SuggestionLanguages.current())) { entry in
                RecommendationTile(result: PodcastSearchResult(
                    title: entry.title, author: entry.author,
                    artworkURL: entry.artworkURL, feedURL: entry.feedURL),
                    subtitle: entry.form?.label,
                    badgeText: entry.ccLicense)
            }
        }
        .padding(.horizontal)
        .padding(.top, TabContentLayout.topInset)
    }

    /// The page order: the popular row on top as a tile row, the newest
    /// titles below it, the genres below that. The page consists
    /// EXCLUSIVELY of tile rows. Endless paging has not disappeared. It lives
    /// on the full page behind the chevron, where scrolling is the form.
    private var catalogGrid: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            // The notice stands at the START of every surface whose content
            // comes from archive.org. LibriVox and Gutenberg carry their own
            // holdings and state their own terms.
            if source == .oldTimeRadio || source == .archiveBooks {
                ArchiveRightsNote()
            }
            popularRow
            // LibriVox keeps its "new additions" as a second lens on the
            // same source. The overview shows one row per source only.
            if source == .librivox, !store.sourceRows.librivoxNew.isEmpty {
                RowHeading.plain("New at LibriVox")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(RowPreview.cut(store.sourceRows.librivoxNew)) { item in
                            tile(item)
                                .cardRowSlot(spacing: 14)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
            // Genres are the STANDARD FORM where the
            // axis carries. Tile row per filled shelf, counting chevron onto
            // the shelf grid.
            if hasChips {
                ForEach(shelfSlots, id: \.key) { slot in
                    if slot.ready {
                        genreRow((key: slot.key, title: slot.title))
                    } else {
                        shelfPlaceholderRow(title: slot.title)
                    }
                }
                ForEach(decadeRows, id: \.key) { decade in
                    decadeRow(decade)
                }
                if showsShelfPlaceholder {
                    shelfPlaceholderRow(title: String(localized: "Loading genres…"))
                }
                // A shelf that could not be ASKED must not look like a
                // shelf the source does not HAVE. Only shown when nothing at
                // all arrived. A partial failure leaves the shelves that did.
                if shelves.isEmpty, !shelfFailures.isEmpty {
                    HStack(spacing: 10) {
                        Text("Genres could not be loaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Retry") {
                            shelfFailures = [:]
                            Task { await loadShelves() }
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.top, TabContentLayout.topInset)
    }

    /// Every surface carries its name. What used to be a nameless endless
    /// grid is the named row at the top, with the chevron onto the full page
    /// where scrolling belongs.
    @ViewBuilder
    private var popularRow: some View {
        let preview = RowPreview.cut(items)
        if !preview.isEmpty {
            RowHeading.entry("Popular", destination: FreeAudiobooksRoute.popular(source))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(preview) { item in
                        tile(item).cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if pageFailure != nil {
            HStack(spacing: 10) {
                Text("Could not load more.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    /// The decades stand BESIDE the genres, not in their place. An item has
    /// both. The usual gate applies: an empty decade gets no row.
    private var decadeRows: [(key: String, title: String)] {
        guard source == .oldTimeRadio else { return [] }
        return CatalogGenreAxis.decadeShelves.filter {
            !(decadeStock[$0.key]?.items.isEmpty ?? true)
        }
    }

    private func decadeRow(_ decade: (key: String, title: String)) -> some View {
        let stock = decadeStock[decade.key]
        let shown = RowPreview.cut(stock?.items ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            if let total = stock?.total {
                RowHeading(title: "", verbatimTitle: decade.title,
                           total: total, shown: shown.count, showsTotal: true,
                           destination: FreeAudiobooksRoute.shelf(source, decade.key))
            } else {
                RowHeading(title: "", verbatimTitle: decade.title, font: .title3,
                           variant: .entry,
                           destination: FreeAudiobooksRoute.shelf(source, decade.key))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shown) { item in
                        tile(item).cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }

    /// A row that already takes its space: the same heading as the real one,
    /// tile skeletons of the same size below it. It replaces itself as soon
    /// as the content arrives, so nothing jumps.
    private func shelfPlaceholderRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.plain(verbatim: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(0..<RowPreview.limit, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                            .cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// One shelf's preview row (filter over `items`).
    ///
    /// On THIS page a title belongs to exactly one shelf. Its
    /// FIRST in browse order. A title that carries Philosophy AND Religion
    /// otherwise stands twice on one screen, which reads as a
    /// bug rather than as the truth of its subjects. On the shelf FULL pages
    /// it may appear in both. There it is the truth.
    @ViewBuilder
    private func genreRow(_ shelf: (key: String, title: String)) -> some View {
        if let stock = shelfStock[shelf.key], !stock.items.isEmpty {
            let shown = RowPreview.cut(stock.items)
            VStack(alignment: .leading, spacing: 10) {
                // The chevron counts the SOURCE's stock. With the pool
                // count it was `1 > 1` for every shelf, so the door to the
                // full shelf was invisible everywhere. The rule was right,
                // it was fed the wrong number.
                if let total = stock.total {
                    RowHeading(title: "", verbatimTitle: shelf.title,
                               total: total, shown: shown.count, showsTotal: true,
                               destination: FreeAudiobooksRoute.shelf(source, shelf.key))
                } else {
                    // Sources whose API does not state a stock (LibriVox
                    // genre feed, gutendex topic): the chevron is earned by
                    // the target's existence. Never by an invented number.
                    RowHeading(title: "", verbatimTitle: shelf.title, font: .title3,
                               variant: .entry,
                               destination: FreeAudiobooksRoute.shelf(source, shelf.key))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shown) { item in
                            tile(item)
                                .cardRowSlot(spacing: 14)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// The stock of every shelf, asked ONCE per visit. The same query the
    /// shelf's full page uses. One truth. Shelves run concurrently
    /// because they are independent; a shelf that fails simply does not
    /// appear, exactly like a shelf without stock.
    /// The shelves ask their OWN source. The gate is booked after the
    /// pass, not before it. A cancelled `.task` (back, tab switch, swipe)
    /// used to leave the gate shut and the shelves gone for the life of the
    /// view.
    ///
    /// And a failure is an ANSWER: a shelf that could not be asked is counted
    /// and named, so a source without stock here and a shelf that could not
    /// be asked stop looking the same.
    private func loadShelves() async {
        guard hasChips, !shelvesLoaded, !shelvesLoading else { return }
        shelvesLoading = true
        defer { shelvesLoading = false }
        let provider = FreeCatalogProvider.shared
        let keys = CatalogGenreAxis.librivoxShelves.map(\.key)
        let languages = SuggestionLanguages.current()
        let source = source
        let storedDay = CatalogShelfSource.storedDay(source: source)
        // gutendex is the smallest of the services and pays 30-41 s for a COLD
        // topic, so it keeps the tighter cap.
        let cap = source == .gutenberg ? 4 : CatalogShelfSource.shelfConcurrency
        var failures: [String: String] = [:]
        await withTaskGroup(of: (String, CatalogShelfSource.Answer?, String?).self) { group in
            var started = 0
            for key in keys {
                // Eighteen at once are neither faster nor polite: measured,
                // the capped pass takes 7,72 s against 8,07 s, because a pass
                // costs its SLOWEST shelf. Eighteen at once was the shape that
                // had the endpoint refuse the connection. The shelves publish
                // as they come, so the cap costs no visible order either.
                if started >= cap {
                    for await answered in group {
                        applyShelf(answered, provider: provider, failures: &failures)
                        break
                    }
                    started -= 1
                }
                group.addTask {
                    do {
                        return (key, try await CatalogShelfSource.preview(
                            source: source, shelf: key, languages: languages,
                            rows: RowPreview.limit, storedDay: storedDay), nil)
                    } catch {
                        return (key, nil, FreeCatalog.failureReason(error))
                    }
                }
                started += 1
            }
            for await answered in group {
                applyShelf(answered, provider: provider, failures: &failures)
            }
        }
        shelfFailures = failures
        // A cancelled pass is not a finished pass. It must be allowed again.
        await loadDecades()
        if !Task.isCancelled { shelvesLoaded = true }
        for (key, reason) in failures {
            Logger.library.error("FREECAT shelf=\(key, privacy: .public) source=\(source.rawValue, privacy: .public) FAILED: \(reason, privacy: .public)")
        }
        Logger.library.notice("FREECAT shelves source=\(source.rawValue, privacy: .public) gefuellt=\(shelfStock.count) fehlgeschlagen=\(failures.count) gebucht=\(!Task.isCancelled)")
    }

    /// The decades, concurrent and in the same shape as the genres. A
    /// failure is named, an empty decade gets no row.
    private func loadDecades() async {
        guard source == .oldTimeRadio else { return }
        let provider = FreeCatalogProvider.shared
        let source = source
        await withTaskGroup(of: (String, [ArchivePopularDoc], Int?, String?).self) { group in
            for decade in CatalogGenreAxis.decadeShelves {
                let key = decade.key
                group.addTask {
                    do {
                        switch try await CatalogShelfSource.decadePage(
                            source: source, decade: key, rows: RowPreview.limit) {
                        case .archive(let docs, let total): return (key, docs, total, nil)
                        default: return (key, [], nil, nil)
                        }
                    } catch {
                        return (key, [], nil, FreeCatalog.failureReason(error))
                    }
                }
            }
            for await (key, docs, total, reason) in group {
                if let reason {
                    Logger.library.error("FREECAT decade=\(key, privacy: .public) FAILED: \(reason, privacy: .public)")
                    continue
                }
                let kept = docs.filter {
                    FreeCatalog.isCuratedArchiveDoc(
                        $0, separatingFromLibriVox: FreeCatalog.separatesFromLibriVox(source))
                }.compactMap { provider.remember(popular: $0) }
                guard !kept.isEmpty else { continue }
                decadeStock[key] = (kept, total)
            }
        }
        Logger.library.notice("FREECAT decades source=\(source.rawValue, privacy: .public) gefuellt=\(decadeStock.count)")
    }

    /// A title may stand in two shelves, because it belongs in both, but not
    /// as a TWIN directly below itself. What already stood higher up on this
    /// page sorts to the back here. It EMPTIES no shelf: the same rule as the
    /// malus of the mixed rows, a move to the back and never a discard.
    private func withoutTwins(_ items: [LibraryItem]) -> [LibraryItem] {
        let oben = Set(shelfStock.values.flatMap { $0.items.prefix(RowPreview.limit) }.map(\.id))
        guard !oben.isEmpty else { return items }
        let frisch = items.filter { !oben.contains($0.id) }
        return frisch + items.filter { oben.contains($0.id) }
    }

    private func applyShelf(_ answered: (String, CatalogShelfSource.Answer?, String?),
                            provider: FreeCatalogProvider,
                            failures: inout [String: String]) {
        let (key, answer, reason) = answered
        if let reason { failures[key] = reason; return }
        switch answer {
        case .archive(let docs, let total):
            let erlaubt = docs.filter {
                FreeCatalog.isCuratedArchiveDoc(
                    $0, separatingFromLibriVox: FreeCatalog.separatesFromLibriVox(source))
            }
            // Multi-author collections stay findable but no longer take the
            // first places. A malus, not an exclusion. It EMPTIES no shelf.
            let einzeln = erlaubt.filter { !FreeCatalog.isMultiAuthorCollection($0) }
            let sammlungen = erlaubt.filter { FreeCatalog.isMultiAuthorCollection($0) }
            let kept = (einzeln + sammlungen).compactMap { provider.remember(popular: $0) }
            guard !kept.isEmpty else { return }
            shelfStock[key] = (withoutTwins(kept), total)
        case .gutenberg(let books, let total):
            let kept = books.compactMap { provider.remember(gutenberg: $0) }
            guard !kept.isEmpty else { return }
            shelfStock[key] = (withoutTwins(kept), total)
        case .unsupported, .none:
            return
        }
    }

    private func tile(_ item: LibraryItem) -> some View {
        // NACHSCHLAGEN. Tap = detail, long-press = Play shortcut.
        // OTR bundles push their show page (episode list).
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: source == .oldTimeRadio ? "waveform.and.mic" : "book.closed",
            onTap: {
                if FreeCatalogProvider.shared.hasPartsList(itemId: item.id) {
                    pushFreeAudiobooksRoute(.series(itemId: item.id))
                } else {
                    detailItem = item
                }
            }
        )
        .contextMenu {
            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: { Label("Play", systemImage: "play.fill") }
        }
    }

    private func seedItems() -> [LibraryItem] {
        CatalogPopularSource.seed(source: source, store: store)
    }

    /// `try?` turned EVERY network error into an end of the list here, on
    /// all four sources. Milder than on the shelves (the page stops paging
    /// instead of looking empty), but the same confusion: a failure looks
    /// like exhaustion and there is no way back. An error does NOT end the
    /// list. It is named and stays repeatable.
    ///
    /// The preview row loads over the SAME path as the full page behind its
    /// chevron (`CatalogPopularSource`). Otherwise the row on top shows a
    /// different excerpt than the page behind it.
    private func load() async {
        guard !source.isFeedBased, !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        #if DEBUG
        if UITestSeed.isActive { reachedEnd = true; return }
        #endif
        switch await CatalogPopularSource.page(
            source: source, page: page, rows: pageSize, unfiltered: languageFallback) {
        case .cancelled:
            return
        case .failed(let reason):
            pageFailure = reason
            Logger.library.error("FREECAT page source=\(source.rawValue, privacy: .public) page=\(page) FAILED: \(reason, privacy: .public)")
        case .loaded(let fresh, let unfiltered, let atEnd):
            languageFallback = unfiltered
            pageFailure = nil
            var seen = Set(items.map(\.id))
            items += fresh.filter { seen.insert($0.id).inserted }
            page += 1
            if atEnd || fresh.isEmpty { reachedEnd = true }
            Logger.library.notice("FREECAT page source=\(source.rawValue, privacy: .public) page=\(page) items=\(items.count)")
        }
    }
}


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

    static func page(source: CatalogSource, page: Int, rows: Int,
                     unfiltered: Bool) async -> Answer {
        let provider = FreeCatalogProvider.shared
        let codes = SuggestionLanguages.current()
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
                let docs = try await ArchiveOrgClient.popularLibriVoxByLanguage(
                    rowsPerLanguage: rows, languageCodes: codes, limit: rows, page: page)
                fresh = curated(docs)
                if docs.count < rows { atEnd = true }
            case .archiveBooks:
                // The fallback is a SESSION state. Once fallen back,
                // deeper pages browse the unfiltered corpus too.
                let result = try await ArchiveOrgClient.audiobooksOutsideLibriVox(
                    rows: rows, languageCodes: codes, page: page, unfiltered: unfiltered)
                fallback = result.unfiltered
                fresh = curated(result.docs)
                if result.docs.count < rows { atEnd = true }
            case .gutenberg:
                var books = try await GutenbergClient.audiobooks(
                    languages: unfiltered ? [] : codes, page: page)
                if books.isEmpty, page == 1, !codes.isEmpty, !unfiltered {
                    books = try await GutenbergClient.audiobooks(languages: [], page: 1)
                    if !books.isEmpty { fallback = true }
                }
                fresh = books.compactMap { provider.remember(gutenberg: $0) }
                if books.isEmpty { atEnd = true }
            case .oldTimeRadio:
                let docs = try await ArchiveOrgClient.popularOldTimeRadio(rows: rows, page: page)
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


/// The full page behind the popular chevron. It is the home of endless
/// paging: the same tile, the same page logic, only without the rows around
/// it. It shares the source page's load path over `CatalogPopularSource`, so
/// preview row and full page show the same stock in the same order.
struct CatalogPopularPage: View {
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @State private var detailItem: LibraryItem?
    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var languageFallback = false
    @State private var pageFailure: String?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    FreeCatalogBookTile(
                        item: item,
                        onTap: {
                            if FreeCatalogProvider.shared.hasPartsList(itemId: item.id) {
                                pushFreeAudiobooksRoute(.series(itemId: item.id))
                            } else {
                                detailItem = item
                            }
                        })
                    .contextMenu {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                    .onAppear {
                        if item.id == items.last?.id { Task { await load() } }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, TabContentLayout.topInset)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if pageFailure != nil {
                // A failure is not exhaustion.
                HStack(spacing: 10) {
                    Text("Could not load more.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            Color.clear.frame(height: 1).bottomBarClearance()
        }
        .navigationTitle(Text("Popular"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty {
                items = CatalogPopularSource.seed(source: source, store: store)
                await load()
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func load() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        #if DEBUG
        if UITestSeed.isActive { reachedEnd = true; return }
        #endif
        let answer = await CatalogPopularSource.page(
            source: source, page: page, rows: pageSize, unfiltered: languageFallback)
        switch answer {
        case .failed(let reason):
            pageFailure = reason
            Logger.library.error("FREECAT popular source=\(source.rawValue, privacy: .public) page=\(page) FAILED: \(reason, privacy: .public)")
        case .cancelled:
            return
        case .loaded(let fresh, let unfiltered, let atEnd):
            languageFallback = unfiltered
            pageFailure = nil
            var seen = Set(items.map(\.id))
            items += fresh.filter { seen.insert($0.id).inserted }
            page += 1
            if atEnd || fresh.isEmpty { reachedEnd = true }
        }
    }
}


/// H erweitert: ONE parameterised shelf grid for the genre-carrying catalog
/// sources. The full filtered stock, staged loading rides the source page's
/// own paging (seeded from the store like CatalogSourcePage).
struct CatalogShelfPage: View {
    let source: CatalogSource
    let shelfKey: String
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detailItem: LibraryItem?
    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reachedEnd = false

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private var title: String {
        CatalogGenreAxis.librivoxShelves.first { $0.key == shelfKey }?.title
            ?? CatalogGenreAxis.decadeShelves.first { $0.key == shelfKey }?.title
            ?? ""
    }

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    FreeCatalogBookTile(
                        item: item,
                        // OTR bundles in shelf grids push their show
                        // page too. Same tap class everywhere.
                        onTap: {
                            if FreeCatalogProvider.shared.hasPartsList(itemId: item.id) {
                                pushFreeAudiobooksRoute(.series(itemId: item.id))
                            } else {
                                detailItem = item
                            }
                        })
                    .contextMenu {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding(.horizontal)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if items.isEmpty && loadFailed {
                // A failed load is not "this shelf is empty".
                ContentUnavailableView {
                    Label(title, systemImage: "books.vertical")
                } description: {
                    Text("Could not load the catalog. Check your connection and try again.")
                } actions: {
                    Button("Retry") { Task { await loadMore(reset: true) } }
                }
                .padding(.top, 40)
            }
            Color.clear.frame(height: 1).bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await loadMore(reset: true) } }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// The shelf ASKS for its shelf instead of filtering the
    /// preview pool. The pool held 12-20 titles, so every shelf of every
    /// source together could never show more than that. The measured stock
    /// is orders of magnitude bigger (LibriVox Poetry ≥1.200, archive.org
    /// philosophy in the thousands). One query per shelf, paged.
    private func loadMore(reset: Bool = false) async {
        guard AppStorageKeys.freeCatalogsMasterActive else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false; items = [] }
        isLoading = true
        defer { isLoading = false }
        let provider = FreeCatalogProvider.shared
        do {
            // One truth: the full page asks the SAME shelf query
            // as the overview row and its chevron. A second query here would
            // promise a stock above that the page below cannot show. And for
            // LibriVox it would also hand back other item ids (`lv:` books
            // instead of the `lva:` documents the row is built from).
            var fresh: [LibraryItem] = []
            switch try await CatalogShelfSource.page(
                source: source, shelf: shelfKey, languages: SuggestionLanguages.current(),
                rows: pageSize, page: page) {
            case .archive(let docs, _):
                // Same gate as the row: de-duplication + denylist, applied
                // wherever the offer is assembled.
                fresh = docs.filter {
                    FreeCatalog.isCuratedArchiveDoc(
                        $0, separatingFromLibriVox: FreeCatalog.separatesFromLibriVox(source))
                }.compactMap { provider.remember(popular: $0) }
            case .gutenberg(let books, _):
                fresh = books.compactMap { provider.remember(gutenberg: $0) }
            case .unsupported:
                reachedEnd = true; return
            }
            Logger.library.notice("FREECAT shelf=\(shelfKey, privacy: .public) source=\(source.rawValue, privacy: .public) page=\(page) loaded=\(fresh.count)")
            if fresh.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += fresh.filter { seen.insert($0.id).inserted }
            page += 1
            if fresh.count < pageSize { reachedEnd = true }
        } catch {
            guard !error.isCancellation else { return }
            Logger.library.error("FREECAT shelf=\(shelfKey, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = items.isEmpty
        }
    }
}


/// The show page of an archive.org SERIES bundle (Old-Time-Radio
/// class). The question "is that really 255 hours without a pause?"
/// answered honestly: the bundle's files ARE episodes, the app knew them all
/// along (FreeCatalog.archiveTracks); this page finally shows them. Blueprint
/// list form like the podcast episode lists; hundreds of episodes page in
/// staged windows like the Fundgruben.
struct ArchiveSeriesPage: View {
    /// One page carries both cases. A radio-play collection is a work in
    /// episodes, a netlabel release an album of tracks. What differs is the
    /// wording ("episodes" against "tracks", first broadcast against plain
    /// running time) and whether a row is an item of its own. Parameterised
    /// instead of a second page.
    enum Flavor { case series, album }

    let itemId: String
    /// The form to show while the item's own is still unknown. It comes from
    /// the route that opened the page and is nothing but a fallback: once the
    /// detail is loaded, the ITEM decides. See `effectiveFlavor`.
    var flavor: Flavor = .series
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detail: LibraryItemDetail?
    /// The cheap head, so the sheet does not wait for the file list.
    @State private var quick: LibraryItemDetail?
    @State private var failed = false
    @State private var visibleCount = 100

    private var tracks: [ABSAudioTrack] { detail?.media.tracks ?? [] }

    /// What the item IS, read from its collections.
    ///
    /// The route used to decide this: reached from the music tab an item was
    /// an album, from the books tab a work. The mixed surfaces can reach
    /// either, so the same reading became an album with a position per track
    /// once it was opened through the album route. And the work's position,
    /// the one place that knew where the listener was, no longer applied.
    private var effectiveFlavor: Flavor {
        switch FreeCatalogProvider.shared.archiveForm(itemId: itemId) {
        case .album: return .album
        case .work:  return .series
        case nil:    return flavor
        }
    }

    /// Which row carries the "last heard" mark.
    ///
    /// The two flavours answer it from different places, because their tracks
    /// are different things. An album track is an item with a position of its
    /// own, so the most recently written SONG wins. A series part is a section
    /// of one work, so the work's single position decides which part it falls
    /// into.
    private var lastHeardIndex: Int? {
        effectiveFlavor == .album ? lastHeardSongIndex : lastHeardSectionIndex
    }

    private var lastHeardSongIndex: Int? {
        var best: (index: Int, stamp: Double)?
        for index in tracks.indices {
            let songId = CatalogSongID.make(album: itemId, index: index)
            guard let mark = ListeningStore.mark(songId), mark.position > 0 else { continue }
            if best == nil || mark.updatedAtMs > best!.stamp {
                best = (index, mark.updatedAtMs)
            }
        }
        return best?.index
    }

    private var lastHeardSectionIndex: Int? {
        let saved = ListeningStore.backup(itemId)
        guard let position = saved?.first else { return nil }
        return FreeCatalog.trackIndex(at: position, tracks: tracks)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // The sheet does NOT wait for the parts list. Measured, the
                // response time hangs on archive.org's queue rather than on
                // the payload size (2 kB in 26 s, 1.3 MB in 11 s), so a
                // smaller request does not help. Moving the wait out of the
                // way does. Head, title and description come at once from the
                // cheap sub-path; the list follows below it, with a NAMED
                // loading state instead of an empty surface.
                if let detail {
                    header(detail)
                    episodeList
                } else if let quick {
                    header(quick)
                    if failed {
                        listProblem
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Loading parts…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                } else if failed {
                    listProblem
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: FreeCatalog.normalizedCollectionTitle(
            detail?.media.metadata?.title ?? "")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Queueing the whole release belongs here; a single track
                    // carries its own buttons in its row.
                    CatalogQueueButtons(itemId: itemId)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityIdentifier("album-actions")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let kopf: Void = loadQuickHeader()
            await load()
            await kopf
        }
    }

    private var listProblem: some View {
        Text("Could not load the episode list. Tap to try again.")
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal)
            .onTapGesture { failed = false; Task { await load() } }
    }

    /// The cheap head: title, creator and description from the sub-path
    /// (8.3 kB instead of 1.36 MB). It runs BESIDE the full fetch, not before
    /// it. Whichever arrives first draws.
    private func loadQuickHeader() async {
        guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return }
        let identifier = String(itemId.dropFirst(FreeCatalog.archivePrefix.count))
        guard let meta = try? await ArchiveOrgClient.metadataOnly(identifier: identifier),
              detail == nil else { return }
        quick = LibraryItemDetail(
            id: itemId,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: meta.title?.joined, authorName: meta.creator?.joined,
                    narratorName: nil, seriesName: nil, genres: nil,
                    publishedYear: nil, description: meta.description?.joined),
                duration: nil, chapters: nil, tracks: nil),
            userMediaProgress: nil)
    }

    private func load() async {
        do {
            detail = try await FreeCatalogProvider.shared.fetchItemDetail(itemId: itemId)
        } catch {
            guard !error.isCancellation else { return }
            failed = true
        }
    }

    @ViewBuilder
    private func header(_ detail: LibraryItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                podcastArtwork(url: AppSession.shared.coverURL(forItemId: itemId),
                               size: 110, corner: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: FreeCatalog.normalizedCollectionTitle(
                        detail.media.metadata?.title ?? ""))
                        .font(.headline)
                    if let author = detail.media.metadata?.authorName {
                        Text(verbatim: author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    // The honest second line. The episode count the tile
                    // could not carry without a second fetch.
                    Text(effectiveFlavor == .album
                         ? "\(tracks.count) tracks"
                         : "\(tracks.count) episodes")
                        .font(.caption).foregroundStyle(.secondary)
                    // Rights capsule: the existing graded truth, never guessed.
                    if let licence = FreeCatalogProvider.shared.licence(forItemId: itemId) {
                        Text(verbatim: licence)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .padding(.horizontal)
            if let description = detail.media.metadata?.description, !description.isEmpty {
                // The leading heading repeats the title and leaves a
                // hole underneath. Both go (measured, see tidiedDescription).
                Text(verbatim: FreeCatalog.tidiedDescription(
                    podcastPlainText(description),
                    title: detail.media.metadata?.title ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(6)
                    .padding(.horizontal)
            }
        }
    }

    /// "07.12.1948 · 29 Min.": date in the user's format, duration in
    /// the existing wording. Either part may be missing; both missing means
    /// no line at all (never an empty separator).
    private func episodeMetaLine(airDate: String?, duration: Double?) -> String? {
        var parts: [String] = []
        if let airDate {
            let iso = DateFormatter()
            // Fixed locale: a fixed format is only fixed with one. Under a
            // non-Gregorian calendar the parse fails and the date silently
            // leaves the line.
            iso.locale = Locale(identifier: "en_US_POSIX")
            iso.dateFormat = "yyyy-MM-dd"
            iso.timeZone = TimeZone(identifier: "UTC")
            if let date = iso.date(from: airDate) {
                parts.append(date.formatted(date: .numeric, time: .omitted))
            }
        }
        if let duration, duration > 0 { parts.append(episodeDurationText(duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var episodeList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.prefix(visibleCount).enumerated()), id: \.offset) { index, track in
                episodeRow(index: index, track: track)
                Divider().padding(.leading, 20)
            }
            if visibleCount < tracks.count {
                Color.clear.frame(height: 1)
                    .onAppear { visibleCount += 100 }
            }
        }
    }

    private func episodeDurationText(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        if total >= 60 { return String(localized: "\(total / 60) h \(total % 60) min") }
        return String(localized: "\(total) min")
    }

    /// The title the ROW shows. The same derivation, so what lands in a
    /// playlist is what the person tapped.
    private func trackTitle(_ track: ABSAudioTrack) -> String {
        let raw = FreeCatalog.trackDisplayTitle(contentUrl: track.contentUrl)
        let stated = track.metadata?.title
        return effectiveFlavor == .series
            ? FreeCatalog.otrEpisode(fromFileName: raw).title
            : (stated ?? raw)
    }

    private func episodeRow(index: Int, track: ABSAudioTrack) -> some View {
        Button {
            Task {
                if effectiveFlavor == .album {
                    // An album track is an item of its own: it plays as itself,
                    // keeps its own position and can be queued or added to a
                    // playlist. A series part stays a section of its work.
                    await playerCoordinator.open(item: LibraryItem(
                        id: CatalogSongID.make(album: itemId, index: index),
                        media: nil, addedAt: nil))
                } else {
                    await playerCoordinator.open(item: LibraryItem(
                        id: itemId, media: detail?.media, addedAt: nil))
                    await playerCoordinator.viewModel?.seek(to: track.startOffset ?? 0)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: "\(index + 1)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
                // The name's housekeeping head (series shorthand,
                // date, running number) is taken OFF the title. But the
                // date is the first broadcast and therefore moves into the
                // meta line instead of being thrown away.
                // The source's own track title wins; the file name stays the
                // fallback for items that state none. The OTR head patterns
                // (shorthand, date, running number) only exist in series.
                // Music track names are left untouched.
                let raw = FreeCatalog.trackDisplayTitle(contentUrl: track.contentUrl)
                let stated = track.metadata?.title
                let episode = effectiveFlavor == .series
                    ? FreeCatalog.otrEpisode(fromFileName: raw)
                    : (title: stated ?? raw, airDate: nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: episode.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let meta = episodeMetaLine(airDate: episode.airDate,
                                                  duration: track.duration) {
                        Text(verbatim: meta)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if lastHeardIndex == index {
                        Text("Last heard")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if effectiveFlavor == .album {
                let songId = CatalogSongID.make(album: itemId, index: index)
                CatalogQueueButtons(itemId: songId)
                // "playlists are SONGS". A catalog track is as
                // enqueueable as a server song, and it hands its title over
                // so a cold cache cannot turn it into a placeholder.
                AddToPlaylistButton(itemId: songId,
                                    knownTitles: [songId: trackTitle(track)])
            }
        }
    }
}
