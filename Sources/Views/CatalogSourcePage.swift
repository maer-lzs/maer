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
    @Environment(\.catalogFacts) private var catalogFacts
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared

    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    /// Language-fallback as SESSION state (one truth, held here).
    @State private var languageFallback = false
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
    @ObservedObject private var stockService = CatalogStockService.shared
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

    /// Which shelves the loaded stock fills. Via the source's OWN spelling
    /// family (LibriVox genre names vs. Gutenberg LCSH subjects).
    /// A shelf appears because the SOURCE has it, not because the
    /// loaded pool happened to contain one of its titles. An empty shelf still
    /// does not show.
    /// A shelf whose stock is empty does not appear at all.
    /// The page's shelf list: the genre shelves, and for the archive
    /// audiobooks the browse-everything shelf at the END (84 % of that
    /// stock carries no subjects; this is their only reachable place).
    private var pageShelves: [(key: String, title: String)] {
        var list = CatalogGenreAxis.librivoxShelves
        // Browse-everything as the LAST shelf: the archive audiobooks
        // (84 percent without subjects) and old-time radio (the shelves
        // reach only the tagged part of 8.793 bundles; decided on the
        // too-small-feeling surface). Same construction, one part, no
        // copy; the licence gate deliberately does NOT apply to the OTR
        // stock (curated period collections, not the pirate-upload
        // nature of the audiobook pot; asked once, answered here). Gutenberg
        // too: its kept stock reaches titles without a genre only here.
        if source == .archiveBooks || source == .oldTimeRadio || source == .gutenberg {
            list.append((CatalogGenreAxis.browseAllKey, CatalogGenreAxis.browseAllTitle))
        }
        return list
    }

    private var shelves: [(key: String, title: String)] {
        guard hasChips else { return [] }
        return pageShelves.filter { shelf in
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
        return pageShelves.compactMap { shelf in
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
        // A kept stock means the shelves come from the device, so there is
        // no wait to announce. The rule still follows the NUMBER: what
        // changed is that the pass is no longer a network question.
        hasChips && !shelvesLoaded && knownShelfKeys.isEmpty
            && stockService.stock(source.rawValue) == nil
            && CatalogShelfSource.showsLoadingPlaceholder(source)
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
            // The first visit of THIS surface fetches THIS collection, and
            // says so. Not a block behind surfaces nobody opens.
            await stockService.ensureStock(
                surface: source.rawValue,
                archiveQuery: ArchiveOrgClient.archiveBaseQuery(for: source))
            knownShelfKeys = CatalogShelfSource.knownShelfKeys(for: source)
            async let shelvesTask: Void = loadShelves(by: "open")
            if items.isEmpty {
                // Seed from the overview's already-loaded preview so the page
                // opens filled, then page onward from the network.
                items = seedItems()
                await load()
            }
            await shelvesTask
            logOverlap(by: "open")
        }
        // The stock landing re-opens the shelves: they deferred to the
        // first fetch above and now answer from the fresh local stock.
        .task(id: stockService.stock(source.rawValue)?.entries.count ?? -1) {
            guard stockService.stock(source.rawValue) != nil else { return }
            shelvesLoaded = false
            await loadShelves(by: "stock")
            logOverlap(by: "stock")
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
                    subtitle: entry.form?.label)
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
        let rows = overviewRows
        return LazyVStack(alignment: .leading, spacing: 14) {
            // The notice stands at the START of every surface whose content
            // comes from archive.org. LibriVox and Gutenberg carry their own
            // holdings and state their own terms.
            if source == .oldTimeRadio || source == .archiveBooks {
                ArchiveRightsNote()
            }
            // A MIXED source states its majority standard once up here; the
            // tiles carry no rights, the detail page names each title's.
            if let note = source.majorityRightsNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            // The first fetch of this collection says that it runs and how
            // far it is. It blocks nothing: the rows below come from the day
            // store meanwhile.
            CatalogStockNotice(state: stockService.state(source.rawValue),
                               collection: source.title,
                               onAllowCellular: {
                                   stockService.allowCellular(
                                       surface: source.rawValue,
                                       archiveQuery: ArchiveOrgClient.archiveBaseQuery(for: source))
                               })
            popularRow(rows.byKey[Self.popularRowKey] ?? [])
            // LibriVox keeps its "new additions" as a second lens on the
            // same source. The overview shows one row per source only.
            if source == .librivox, let fresh = rows.byKey[Self.newRowKey], !fresh.isEmpty {
                RowHeading.plain("New at LibriVox")
                previewStrip(fresh)
            }
            // Genres are the STANDARD FORM where the
            // axis carries. Tile row per filled shelf, counting chevron onto
            // the shelf grid.
            if hasChips {
                ForEach(shelfSlots, id: \.key) { slot in
                    if slot.ready {
                        genreRow((key: slot.key, title: slot.title),
                                 shown: rows.byKey[Self.shelfRowKey(slot.key)] ?? [])
                    } else {
                        shelfPlaceholderRow(title: slot.title)
                    }
                }
                ForEach(decadeRows, id: \.key) { decade in
                    decadeRow(decade, shown: rows.byKey[Self.decadeRowKey(decade.key)] ?? [])
                }
                if showsShelfPlaceholder {
                    shelfPlaceholderRow(title: String(localized: "Loading genres…"))
                }
                if ShelvesFailedLine.isShown(arrived: shelves.count, failed: shelfFailures.count) {
                    ShelvesFailedLine {
                        shelfFailures = [:]
                        Task { await loadShelves(by: "retry") }
                    }
                }
            }
        }
        .padding(.top, TabContentLayout.topInset)
    }

    /// Every surface carries its name. What used to be a nameless endless
    /// grid is the named row at the top, with the chevron onto the full page
    /// where scrolling belongs.
    @ViewBuilder
    private func popularRow(_ preview: [LibraryItem]) -> some View {
        if !preview.isEmpty {
            RowHeading.entry("Popular", destination: FreeAudiobooksRoute.popular(source))
            previewStrip(preview)
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if pageFailure != nil {
            LoadFailedView(form: .line, sentence: "Could not load more.") { Task { await load() } }
                .padding()
        }
    }

    /// THE preview row of the overview: the row's share of the split as
    /// tiles side by side. Popular, New at LibriVox, the shelves and the
    /// decades draw through it.
    private func previewStrip(_ shown: [LibraryItem]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(shown) { item in
                    tile(item).cardRowSlot(spacing: 14)
                }
            }
            .padding(.horizontal)
        }
        .rowReachesUnderSideColumn()
    }

    /// The heading of a shelf or decade row. The chevron counts the
    /// SOURCE's stock; with the pool count it was `1 > 1` for every shelf,
    /// so the door to the full shelf was invisible everywhere. Sources whose
    /// API states no stock (LibriVox genre feed, gutendex topic) earn the
    /// chevron by the target's existence, never by an invented number.
    @ViewBuilder
    private func stockHeading(title: String, total: Int?, shown: Int, key: String) -> some View {
        if let total {
            RowHeading(title: "", verbatimTitle: title, total: total, shown: shown, showsTotal: true,
                       destination: FreeAudiobooksRoute.shelf(source, key))
        } else {
            RowHeading(title: "", verbatimTitle: title, font: .title3, variant: .entry,
                       destination: FreeAudiobooksRoute.shelf(source, key))
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

    static let popularRowKey = "popular"
    static let newRowKey = "new"
    static func shelfRowKey(_ key: String) -> String { "shelf." + key }
    static func decadeRowKey(_ key: String) -> String { "decade." + key }

    /// The overview's rows in page order (popular, new at LibriVox, the
    /// filled shelves, the decades), each title once, spread evenly with
    /// Popular as the buffer (`CatalogPageOverlap.balanced`). Drawing and the
    /// page's log line read this one split.
    private var overviewRows: (byKey: [String: [LibraryItem]], rows: [[LibraryItem]],
                               emptied: Int, shorter: Int, refilled: Int) {
        var keys = [Self.popularRowKey]
        var stocks = [items]
        if source == .librivox {
            keys.append(Self.newRowKey)
            stocks.append(store.sourceRows.librivoxNew)
        }
        for slot in shelfSlots where slot.ready {
            keys.append(Self.shelfRowKey(slot.key))
            stocks.append(shelfStock[slot.key]?.items ?? [])
        }
        for decade in decadeRows {
            keys.append(Self.decadeRowKey(decade.key))
            stocks.append(decadeStock[decade.key]?.items ?? [])
        }
        // Popular is the first row and the buffer: it fetches more than it shows.
        let kept = CatalogPageOverlap.balanced(stocks, buffer: 0, limit: RowPreview.limit)
        return (Dictionary(zip(keys, kept), uniquingKeysWith: { first, _ in first }), kept,
                CatalogPageOverlap.emptied(stocks, to: kept),
                CatalogPageOverlap.shorter(stocks, to: kept, limit: RowPreview.limit),
                CatalogPageOverlap.refilled(stocks[0], to: kept[0], limit: RowPreview.limit))
    }

    /// One line per finished pass: how many titles stand in more than one
    /// row, and how many rows the split leaves without a title of their own
    /// (`CatalogPageOverlap.speaks` says when).
    private func logOverlap(by caller: String) {
        guard CatalogPageOverlap.speaks(feedBased: source.isFeedBased, hasShelves: hasChips,
                                        shelvesLoaded: shelvesLoaded) else { return }
        let split = overviewRows
        let count = CatalogPageOverlap.count(rows: split.rows.map { $0.map(\.id) })
        Logger.library.notice("CATALOG page source=\(source.rawValue, privacy: .public) by=\(caller, privacy: .public) rows=\(count.rows) titles=\(count.titles) duplicates=\(count.duplicates) emptied=\(split.emptied) shorter=\(split.shorter) refilled=\(split.refilled) examples=\(count.examples.joined(separator: ","), privacy: .public)")
    }

    /// A decade's preview row; `shown` is its share of the overview split.
    @ViewBuilder
    private func decadeRow(_ decade: (key: String, title: String), shown: [LibraryItem]) -> some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                stockHeading(title: decade.title, total: decadeStock[decade.key]?.total, shown: shown.count, key: decade.key)
                previewStrip(shown)
            }
        }
    }

    /// The shared placeholder row. It lives in `TabContentLayout` because
    /// the two music surfaces wait the same way and must not grow a copy.
    private func shelfPlaceholderRow(title: String) -> some View {
        ShelfPlaceholderRow(title: title)
    }

    /// One shelf's preview row, from the shelf's own stock.
    ///
    /// Each row asks its source for its own shelf, so a title that carries
    /// two subjects is in both stocks; on the overview it stands in one
    /// row only (`shown`, the row's share of the split), and its full shelf
    /// page keeps the whole stock.
    @ViewBuilder
    private func genreRow(_ shelf: (key: String, title: String), shown: [LibraryItem]) -> some View {
        if let stock = shelfStock[shelf.key], !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                stockHeading(title: shelf.title, total: stock.total, shown: shown.count, key: shelf.key)
                previewStrip(shown)
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
    /// One pass over the shelves. `caller` names what started it (the
    /// first visit, a landing of the stock, the retry line); the pass's line
    /// says it with how each answer came, so a pass that asks the network is
    /// told from one that only redraws.
    private func loadShelves(by caller: String) async {
        guard hasChips, !shelvesLoaded, !shelvesLoading else { return }
        shelvesLoading = true
        defer { shelvesLoading = false }
        let keys = pageShelves.map(\.key)
        let languages = SuggestionLanguages.current()
        let source = source
        let storedDay = CatalogShelfSource.storedDay(source: source)
        // The kept stock, read ONCE per pass. Where it answers, no shelf
        // asks the network at all.
        let keptStock = stockService.stock(source.rawValue)
        // And its subject index, built once per session: eighteen shelves
        // are eighteen bucket lookups, not eighteen scans of 75.000 entries.
        let keptIndex = stockService.index(source.rawValue)
        // The FIRST fetch has right of way. While the stock run is on the
        // wire, eighteen shelf service queries would join the very burst
        // that had archive.org refuse connections (-1004, measured on the
        // device; the gutendex shelves died in its wake). The shelves wait;
        // the moment the stock lands they answer LOCALLY, without any
        // network at all. Only a RUNNING fetch defers; a cellular question
        // or a failed state must not park the shelves forever.
        if keptStock == nil,
           case .loading = stockService.state(source.rawValue) {
            shelvesLoading = false
            return
        }
        // The STORED state is drawn first, completely, and synchronously.
        //
        // Without this the page rebuilt itself in front of the reader: the
        // shelf rows live in view state, so every rebuild started from
        // nothing and filled in again one answer at a time, and a warm
        // visit looked exactly like a cold one. What is already known
        // belongs on the screen before anything is asked.
        seedShelvesFromStore(storedDay: storedDay, keptStock: keptStock,
                             keptIndex: keptIndex)
        // gutendex is the smallest of the services and pays 30-41 s for a COLD
        // topic, so it keeps the tighter cap.
        let cap = source == .gutenberg ? 4 : CatalogShelfSource.shelfConcurrency
        var failures: [String: String] = [:]
        var ways: [CatalogShelfSource.Way] = []
        await withTaskGroup(of: (String, CatalogShelfSource.Answer?, String?, CatalogShelfSource.Way?).self) { group in
            var started = 0
            for key in keys {
                // Eighteen at once are neither faster nor polite: measured,
                // the capped pass takes 7,72 s against 8,07 s, because a pass
                // costs its SLOWEST shelf. Eighteen at once was the shape that
                // had the endpoint refuse the connection. The shelves publish
                // as they come, so the cap costs no visible order either.
                if started >= cap {
                    for await (key, answer, reason, way) in group {
                        if let way { ways.append(way) }
                        applyShelf((key, answer, reason), failures: &failures)
                        break
                    }
                    started -= 1
                }
                group.addTask {
                    do {
                        let (answer, way) = try await CatalogShelfSource.preview(
                            source: source, shelf: key, languages: languages,
                            rows: RowPreview.limit, storedDay: storedDay,
                            keptStock: keptStock, keptIndex: keptIndex)
                        return (key, answer, nil, way)
                    } catch {
                        // A throw came from the network: the stock and the day
                        // store answer without one.
                        return (key, nil, await CatalogPageFailure.sentence(for: error, at: "source-section"), .network)
                    }
                }
                started += 1
            }
            for await (key, answer, reason, way) in group {
                if let way { ways.append(way) }
                applyShelf((key, answer, reason), failures: &failures)
            }
        }
        // The order is decided ONCE, over the browse order, after everything
        // has arrived. Deciding it per arrival made the same day look
        // different on two passes.
        shelfStock = twinFree(shelfStock)
        shelfFailures = failures
        // A cancelled pass is not a finished pass. It must be allowed again.
        ways += await loadDecades()
        // Neither is a pass that brought NOTHING and reported NOTHING.
        //
        // A shelf whose request was cancelled answers with no content and no
        // reason, because a cancellation is deliberately not a failure. If
        // every shelf answers that way and the pass books itself as loaded,
        // the surface loses its placeholder, gets no failure line and stands
        // there empty without a word. That is exactly the state the cold
        // archive surface was found in.
        let leerUndStumm = shelfStock.isEmpty && failures.isEmpty
        if !Task.isCancelled && !leerUndStumm { shelvesLoaded = true }
        for (key, reason) in failures {
            Logger.library.error("FREECAT shelf=\(key, privacy: .public) source=\(source.rawValue, privacy: .public) FAILED: \(reason, privacy: .public)")
        }
        // A pass with nothing filled and nothing failed names what it stood
        // on: whether a stock was there, and whether the pass was cancelled.
        // Twice on the device the line said 0 and 0 and nothing else.
        let stockCount = keptStock.map { String($0.entries.count) } ?? "none"
        Logger.library.notice("FREECAT shelves source=\(source.rawValue, privacy: .public) gefuellt=\(shelfStock.count) fehlgeschlagen=\(failures.count) gebucht=\(!Task.isCancelled && !leerUndStumm) stock=\(stockCount, privacy: .public) cancelled=\(Task.isCancelled) by=\(caller, privacy: .public) \(CatalogShelfSource.Way.tally(ways), privacy: .public)")
    }

    /// The decades, concurrent and in the same shape as the genres. A
    /// failure is named, an empty decade gets no row.
    /// The decades' ways, for the line of the pass that ran them.
    private func loadDecades() async -> [CatalogShelfSource.Way] {
        guard source == .oldTimeRadio else { return [] }
        let source = source
        // The decades are shelves of the same surface, so they take the same
        // day store. Four queries, so they need no cap of their own.
        let storedDay = CatalogShelfSource.storedDay(surface: source.rawValue)
        var ways: [CatalogShelfSource.Way] = []
        await withTaskGroup(of: (String, [ArchivePopularDoc], Int?, String?, CatalogShelfSource.Way).self) { group in
            for decade in CatalogGenreAxis.decadeShelves {
                let key = decade.key
                group.addTask {
                    do {
                        let (answer, way) = try await CatalogShelfSource.decadePreview(
                            source: source, decade: key, rows: RowPreview.limit,
                            storedDay: storedDay)
                        switch answer {
                        case .archive(let docs, let total): return (key, docs, total, nil, way)
                        default: return (key, [], nil, nil, way)
                        }
                    } catch {
                        return (key, [], nil, await CatalogPageFailure.sentence(for: error, at: "source-shelf"), .network)
                    }
                }
            }
            for await (key, docs, total, reason, way) in group {
                ways.append(way)
                if let reason {
                    Logger.library.error("FREECAT decade=\(key, privacy: .public) FAILED: \(reason, privacy: .public)")
                    continue
                }
                let kept = CatalogShelfEntries.books(docs, source: source)
                guard !kept.isEmpty else { continue }
                decadeStock[key] = (kept, total)
            }
        }
        Logger.library.notice("FREECAT decades source=\(source.rawValue, privacy: .public) gefuellt=\(decadeStock.count)")
        return ways
    }

    /// The shared twin rule over this page's browse order; the rule itself
    /// lives beside the shelf salt in `CatalogRotation`, because every
    /// surface with shelves needs it and one copy per door drifts.
    private func twinFree(_ stock: [String: (items: [LibraryItem], total: Int?)])
        -> [String: (items: [LibraryItem], total: Int?)] {
        CatalogRotation.twinFree(stock, order: pageShelves.map(\.key),
                                 previewLimit: RowPreview.limit)
    }

    /// Everything the device already knows, drawn before the first request.
    /// Pure reading: the day store and the kept stock, through the same
    /// entry point the network answers take, so a seeded row and a fetched
    /// row are the same row.
    private func seedShelvesFromStore(storedDay: [String: CatalogShelfSource.ShelfStock?],
                                      keptStock: CatalogStock?,
                                      keptIndex: CatalogStockIndex?) {
        var failures: [String: String] = [:]
        for shelf in pageShelves {
            if let stock = keptStock,
               let local = CatalogShelfSource.localShelf(surface: source.rawValue,
                                                         shelf: shelf.key,
                                                         rows: RowPreview.limit, stock: stock,
                                                         index: keptIndex) {
                applyShelf((shelf.key, local, nil), failures: &failures)
                continue
            }
            if let stored = storedDay[shelf.key] {
                applyShelf((shelf.key, CatalogShelfSource.answer(from: stored, source: source),
                            nil), failures: &failures)
            }
        }
        shelfStock = twinFree(shelfStock)
    }

    private func applyShelf(_ answered: (String, CatalogShelfSource.Answer?, String?),
                            failures: inout [String: String]) {
        let (key, answer, reason) = answered
        if let reason { failures[key] = reason; return }
        // Multi-author collections stay findable but behind the single works.
        guard let shelf = CatalogShelfEntries.shelf(answer, source: source, collectionsLast: true),
              !shelf.items.isEmpty else { return }
        shelfStock[key] = shelf
    }

    private func tile(_ item: LibraryItem) -> some View {
        // NACHSCHLAGEN. Tap = detail, long-press = Play shortcut.
        // OTR bundles push their show page (episode list).
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: source == .oldTimeRadio ? "waveform.and.mic" : "book.closed",
            onTap: {
                pushFreeAudiobooksRoute(catalogFacts.route(item.id))
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


/// The full page behind the popular chevron. It is the home of endless
/// paging: the same tile, the same page logic, only without the rows around
/// it. It shares the source page's load path over `CatalogPopularSource`, so
/// preview row and full page show the same stock in the same order.
struct CatalogPopularPage: View {
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @Environment(\.catalogFacts) private var catalogFacts
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
                            pushFreeAudiobooksRoute(catalogFacts.route(item.id))
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
                LoadFailedView(form: .line, sentence: "Could not load more.") { Task { await load() } }
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
    @Environment(\.catalogFacts) private var catalogFacts
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var reachedEnd = false

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private var title: String {
        shelfKey == CatalogGenreAxis.browseAllKey
            ? CatalogGenreAxis.browseAllTitle
            : CatalogGenreAxis.librivoxShelves.first { $0.key == shelfKey }?.title
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
                            pushFreeAudiobooksRoute(catalogFacts.route(item.id))
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
                LoadFailedView(form: .page(title: Text(verbatim: title), systemImage: "books.vertical"),
                               sentence: "Could not load the catalog. Check your connection and try again.") {
                    Task { await loadMore(reset: true) }
                }
                .padding(.top, 40)
            }
            Color.clear.frame(height: 1).bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await loadMore(reset: true) } }
    }

    /// The shelf ASKS for its shelf instead of filtering the
    /// preview pool. The pool held 12-20 titles, so every shelf of every
    /// source together could never show more than that. The measured stock
    /// is orders of magnitude bigger (LibriVox Poetry ≥1.200, archive.org
    /// philosophy in the thousands). One query per shelf, paged.
    private func loadMore(reset: Bool = false) async {
        // The page asks ITS source, not some master: a switched-off source
        // starts no request even while the route is still open.
        guard source.isAllowed else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false; items = [] }
        isLoading = true
        defer { isLoading = false }
        do {
            // One truth: the full page asks the SAME shelf query
            // as the overview row and its chevron. A second query here would
            // promise a stock above that the page below cannot show. And for
            // LibriVox it would also hand back other item ids (`lv:` books
            // instead of the `lva:` documents the row is built from).
            //
            // The END belongs to the SOURCE's raw answer, never to the
            // count that survives the app-side gates: a page where
            // curation or de-duplication eats a few titles used to end
            // the whole page ("finished after the first sweep" on a stock
            // of thousands), and a fully eaten page stopped feeding the
            // appear trigger. Hence the bounded catch-up loop: keep
            // paging until something new appended or the source itself
            // ran short.
            var appended = 0
            var hops = 0
            while appended == 0, !reachedEnd, hops < 5 {
                hops += 1
                var fresh: [LibraryItem] = []
                var rawCount = 0
                switch try await CatalogShelfSource.page(
                    source: source, shelf: shelfKey, languages: SuggestionLanguages.current(),
                    rows: pageSize, page: page,
                    keptStock: CatalogStockService.shared.stock(source.rawValue),
                    keptIndex: CatalogStockService.shared.index(source.rawValue)) {
                case .archive(let docs, _):
                    rawCount = docs.count
                    // Same gate as the row: de-duplication + denylist,
                    // applied wherever the offer is assembled.
                    fresh = CatalogShelfEntries.books(docs, source: source)
                case .gutenberg(let books, _):
                    rawCount = books.count
                    fresh = CatalogShelfEntries.books(books)
                case .unsupported:
                    reachedEnd = true; return
                }
                Logger.library.notice("FREECAT shelf=\(shelfKey, privacy: .public) source=\(source.rawValue, privacy: .public) page=\(page) raw=\(rawCount) loaded=\(fresh.count)")
                if rawCount < pageSize { reachedEnd = true }
                page += 1
                var seen = Set(items.map(\.id))
                let neu = fresh.filter { seen.insert($0.id).inserted }
                items += neu
                appended += neu.count
            }
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
    @Environment(\.catalogFacts) private var catalogFacts
    @Environment(\.itemRouter) private var router
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
    @State private var failedReason = ""
    @State private var visibleCount = 100
    /// How many of the album's songs did not resolve when it was last
    /// started; the line under the buttons says it.
    @State private var missingSongs = 0

    private var tracks: [ABSAudioTrack] { detail?.media.tracks ?? [] }

    /// "1 track not available": the line under an album's buttons when
    /// songs did not resolve; none when all did.
    nonisolated static func missingSongsLine(count: Int) -> String? {
        count > 0 ? String(localized: "\(count) tracks not available") : nil
    }

    /// What the item IS, read from its collections.
    ///
    /// The route used to decide this: reached from the music tab an item was
    /// an album, from the books tab a work. The mixed surfaces can reach
    /// either, so the same reading became an album with a position per track
    /// once it was opened through the album route. And the work's position,
    /// the one place that knew where the listener was, no longer applied.
    private var effectiveFlavor: Flavor {
        // Only an archive item can be an album; a reading of another source
        // (Gutenberg, LibriVox) is a work whatever the route said.
        guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return .series }
        switch catalogFacts.archiveForm(itemId) {
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
        // In a wide window the head stands beside the parts, divided at the
        // fold (`DetailScrollColumns`).
        DetailScrollColumns(spacing: 14) {
            // The sheet does NOT wait for the parts list. Measured, the
            // response time hangs on archive.org's queue rather than on
            // the payload size (2 kB in 26 s, 1.3 MB in 11 s), so a
            // smaller request does not help. Moving the wait out of the
            // way does. Head, title and description come at once from the
            // cheap sub-path; the list follows below it, with a NAMED
            // loading state instead of an empty surface.
            if let head = detail ?? quick {
                header(head)
            }
        } content: {
            if detail != nil {
                episodeList
            } else if quick != nil {
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
        .untitledDetailPage()
        // Queueing the whole release belongs in the page's menu; a single
        // track carries its own buttons in its row.
        .pageActions("album-actions") {
            CatalogQueueButtons(itemId: itemId)
        }
        .task {
            async let kopf: Void = loadQuickHeader()
            await load()
            await kopf
        }
    }

    private var listProblem: some View {
        // The reason in plain words; the measured one (status, transport
        // error, decode) is in the log line (`CatalogPageFailure`).
        LoadFailedView(form: .line,
                       sentence: Text("Could not load the episode list.")
                           + Text(verbatim: failedReason.isEmpty ? "" : " (\(failedReason))")) {
            failed = false
            Task { await load() }
        }
        .padding(.horizontal)
    }

    /// The cheap head: title, creator and description from the sub-path
    /// (8.3 kB instead of 1.36 MB). It runs BESIDE the full fetch, not before
    /// it. Whichever arrives first draws.
    private func loadQuickHeader() async {
        guard case .found(let meta) = await ArchiveMetadataLoader.quickMetadata(forItemId: itemId),
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
            detail = try await router.provider(itemId).fetchItemDetail(itemId: itemId)
        } catch {
            // Cancellation is not a failure; the page asks again when it
            // appears next. Said in the log so a stuck page can be read.
            guard !error.isCancellation else {
                Logger.library.notice("CATALOG detail cancelled ns=\(ItemNamespace.of(itemId) ?? "-", privacy: .public)")
                return
            }
            failedReason = await CatalogPageFailure.sentence(for: error, at: "detail") ?? ""
            failed = true
        }
    }

    @ViewBuilder
    private func header(_ detail: LibraryItemDetail) -> some View {
        DetailHeader(title: FreeCatalog.normalizedCollectionTitle(detail.media.metadata?.title ?? "")) { side in
            // An album takes the album page's measure, a series the show's.
            podcastArtwork(url: router.coverURL(itemId),
                           size: side ?? (effectiveFlavor == .album ? 240 : 150),
                           corner: DetailCoverCard.cornerRadius)
                .coverCard()
        } lines: {
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
            if let licence = catalogFacts.licence(itemId) {
                Text(verbatim: licence)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        } facts: {
            if let description = detail.media.metadata?.description, !description.isEmpty {
                // The leading heading repeats the title and leaves a
                // hole underneath. Both go (measured, see tidiedDescription).
                Text(verbatim: FreeCatalog.tidiedDescription(
                    podcastPlainText(description),
                    title: detail.media.metadata?.title ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        } actions: {
            // An album starts like one: its tracks in order, or shuffled.
            if effectiveFlavor == .album {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        // While the release or one of its songs plays, the
                        // button pauses it, as on a server's album page.
                        if let vm = playerCoordinator.viewModel,
                           playerCoordinator.activeItem.map({ CatalogSongID.album(of: $0.id) }) == itemId {
                            ActiveAlbumPlayButton(viewModel: vm)
                                .disabled(tracks.isEmpty)
                        } else {
                            DetailMainButton(title: String(localized: "Play"), systemImage: "play.fill") {
                                Task {
                                    await playerCoordinator.playInOrder(items: await albumSongs(),
                                                                        contextSource: detail.media.metadata?.title)
                                }
                            }
                            .disabled(tracks.isEmpty)
                        }
                        ShufflePlayButton(playerCoordinator: playerCoordinator, style: .icon) { await albumSongs() }
                            .font(.title3)
                            .disabled(tracks.isEmpty)
                    }
                    if let line = Self.missingSongsLine(count: missingSongs) {
                        Text(verbatim: line)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("album-songs-missing")
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// The album's tracks as the items they are (`CatalogSongID`), in order,
    /// from the catalogue's one list of a release's songs. A song that does
    /// not resolve is counted under the buttons and named in the log; the
    /// rest plays.
    private func albumSongs() async -> [LibraryItem] {
        let answer = await FreeCatalogProvider.shared.albumSongs(albumId: itemId, count: tracks.count)
        missingSongs = answer.missing.count
        if !answer.missing.isEmpty {
            Logger.library.notice("CATALOG album songs missing=\(answer.missing.count) of=\(tracks.count) first=\(answer.missing[0]) ns=\(ItemNamespace.of(itemId) ?? "-", privacy: .public)")
        }
        return answer.songs
    }

    /// "07.12.1948 · 29 Min.": date in the user's format, duration in
    /// the existing wording. Either part may be missing; both missing means
    /// no line at all (never an empty separator).
    private func episodeMetaLine(airDate: String?, duration: Double?) -> String? {
        var parts: [String] = []
        if let airDate, let day = EpisodeDateLine.airDay(airDate) { parts.append(day) }
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
        DurationText.length(seconds: seconds)
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
                    await playerCoordinator.open(itemId: CatalogSongID.make(album: itemId, index: index))
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
                // "playlists are SONGS". A catalog track is as enqueueable
                // as a server song; the shared block carries the ONE
                // playlist action and takes the title along, so a cold
                // cache cannot turn it into a placeholder.
                CatalogQueueButtons(itemId: songId, knownTitles: [songId: trackTitle(track)])
            }
        }
    }
}
