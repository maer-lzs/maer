// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE page for every archive.org music area
/// (classical · netlabels · the 78 rpm genre shelves). External free catalog,
/// clearly marked as such (header line + licence capsule/detail sheet);
/// NEVER mixed into the personal library surfaces. Popularity-sorted grid
/// (archive.org downloads), paged; tiles play directly, context menu opens
/// the licence sheet.
///
/// There is no second page of this shape. The area carries what differs
/// (query, title, note, symbol).
struct ArchiveMusicPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let area: ArchiveMusicArea
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?
    /// The stock per shelf. The same construction as `CatalogShelfSource`:
    /// a shelf appears because the SOURCE has it.
    @State private var shelfStock: [String: (items: [LibraryItem], total: Int?)] = [:]
    @State private var shelvesLoaded = false
    @State private var shelvesLoading = false
    @ObservedObject private var stockService = CatalogStockService.shared

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            if items.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                if loadFailed {
                    ContentUnavailableView {
                        Label(area.title, systemImage: area.placeholderSystemImage)
                    } description: {
                        Text("Could not load the catalog. Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await loadMore(reset: true) } }
                    }
                } else {
                    ContentUnavailableView(area.title, systemImage: area.placeholderSystemImage)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Clear external-catalog marking (Katalog ≠ Bibliothek).
                        Text(area.headerNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        ArchiveRightsNote()
                        // First visit of THIS collection fetches it and says
                        // so. The rows below come from the day store
                        // meanwhile.
                        CatalogStockNotice(state: stockService.state(area.key),
                                           collection: area.title)
                        // The same order as on the catalog pages: the
                        // popular row sits ON TOP as a tile row with a
                        // chevron, the shelves below it. Endless paging
                        // lives on the full page behind the chevron, where
                        // scrolling is the form.
                        if area.hasGenreShelves {
                            popularRow
                            ForEach(genreShelves, id: \.key) { shelf in
                                genreRow(shelf)
                            }
                            // The same rule as on the book surfaces, not a
                            // second one: the cold pass over this endpoint
                            // takes long enough to be worth saying, and a
                            // stored day means the tiles are already there.
                            if showsShelfPlaceholder {
                                ShelfPlaceholderRow(title: String(localized: "Loading genres…"))
                            }
                        } else {
                            CoverGrid(columns: columns) {
                            ForEach(items) { item in
                                // Shared catalog tile: carries the
                                // licence capsule. Which is what
                                // makes the CC-licensed netlabel releases
                                // honest at a glance.
                                FreeCatalogBookTile(
                                    item: item,
                                    placeholderSystemImage: area.placeholderSystemImage,
                                    hidesUnstatedRights: area.statesUniformRights,
                                    // Same tap convention as every other
                                    // catalogue surface: one track plays,
                                    // several open the album page. This one
                                    // still started the whole release.
                                    onTap: {
                                        Task {
                                            await CatalogTap.open(item: item,
                                                                  coordinator: playerCoordinator,
                                                                  pushMusicRoute: { pushRoute($0) })
                                        }
                                    }
                                )
                                .contextMenu {
                                    Button {
                                        detailItem = item
                                    } label: { Label("Details", systemImage: "info.circle") }
                        CatalogQueueButtons(itemId: item.id)
                                }
                                .onAppear {
                                    if item.id == items.last?.id { Task { await loadMore() } }
                                }
                            }
                        }
                            .padding(.horizontal)
                            if isLoading && !items.isEmpty {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text(area.title))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await CatalogShuffle.play(area: area, coordinator: playerCoordinator) }
                } label: {
                    Image(systemName: "shuffle")
                }
                .accessibilityLabel(Text("Play something at random"))
                .accessibilityIdentifier("catalog-shuffle")
            }
        }
        .task {
            async let stockTask: Void = CatalogStockService.shared.ensureStock(
                surface: area.key, archiveQuery: area.query)
            async let shelvesTask: Void = loadShelves()
            if items.isEmpty { await loadMore(reset: true) }
            await shelvesTask
            await stockTask
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    /// The same shape as `CatalogSourcePage.popularRow`: a named row with a
    /// chevron, endless paging on the full page behind it.
    @ViewBuilder
    private var popularRow: some View {
        let preview = RowPreview.cut(items)
        if !preview.isEmpty {
            RowHeading.entry("Popular", destination: MusicRoute.archiveMusicPopular(area.key))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(preview) { item in
                        FreeCatalogBookTile(
                            item: item,
                            placeholderSystemImage: area.placeholderSystemImage,
                            hidesUnstatedRights: area.statesUniformRights,
                            onTap: {
                                Task {
                                    await CatalogTap.open(item: item,
                                                          coordinator: playerCoordinator,
                                                          pushMusicRoute: { pushRoute($0) })
                                }
                            })
                        .contextMenu {
                            Button { detailItem = item } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            CatalogQueueButtons(itemId: item.id)
                        }
                        .cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }

    /// A shelf appears only when the source fills it.
    /// The cold first visit says so; a stored day does not, because its
    /// tiles are already on screen and a skeleton flashing over them IS the
    /// layout shift it exists against.
    private var showsShelfPlaceholder: Bool {
        area.hasGenreShelves && !shelvesLoaded
            && CatalogShelfSource.storedDay(surface: area.key).isEmpty
            && stockService.stock(area.key) == nil
            && CatalogShelfSource.showsLoadingPlaceholder(surface: area.key)
    }

    private var genreShelves: [(key: String, title: String)] {
        guard area.hasGenreShelves else { return [] }
        return CatalogGenreAxis.musicShelves.filter {
            !(shelfStock[$0.key]?.items.isEmpty ?? true)
        }
    }

    private func genreRow(_ shelf: (key: String, title: String)) -> some View {
        let stock = shelfStock[shelf.key]
        let shown = stock?.items.count ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            if let total = stock?.total {
                RowHeading(title: "", verbatimTitle: shelf.title,
                           total: total, shown: shown, showsTotal: true,
                           destination: MusicRoute.archiveMusicShelf(area: area.key,
                                                                     shelf: shelf.key))
            } else {
                RowHeading(title: "", verbatimTitle: shelf.title, font: .title3,
                           variant: .entry,
                           destination: MusicRoute.archiveMusicShelf(area: area.key,
                                                                     shelf: shelf.key))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(stock?.items ?? []) { item in
                        FreeCatalogBookTile(
                            item: item,
                            placeholderSystemImage: area.placeholderSystemImage,
                            hidesUnstatedRights: area.statesUniformRights,
                            onTap: {
                                Task {
                                    await CatalogTap.open(item: item,
                                                          coordinator: playerCoordinator,
                                                          pushMusicRoute: { pushRoute($0) })
                                }
                            })
                        .contextMenu {
                            Button { detailItem = item } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            CatalogQueueButtons(itemId: item.id)
                        }
                        .cardRowSlot(spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }

    /// Ask the STOCK per shelf (the same query the full page uses), book the
    /// gate AFTER the pass, a cancellation reopens it, and a failure is an
    /// answer instead of an empty shelf.
    private func loadShelves() async {
        guard area.hasGenreShelves, !shelvesLoaded, !shelvesLoading else { return }
        guard AppStorageKeys.archiveServiceActive else { return }
        shelvesLoading = true
        defer { shelvesLoading = false }
        let area = area
        // The same door, the same day store and the same cap as the book
        // shelves. The query used to be built here, which is why this surface
        // had neither of the two.
        let storedDay = CatalogShelfSource.storedDay(surface: area.key)
        // The kept stock answers first where it can, read once per pass.
        let keptStock = CatalogStockService.shared.stock(area.key)
        let keptIndex = CatalogStockService.shared.index(area.key)
        var failures = 0
        await withTaskGroup(of: (String, [ArchivePopularDoc], Int?, String?).self) { group in
            var started = 0
            for shelf in CatalogGenreAxis.musicShelves {
                let key = shelf.key
                guard !CatalogGenreAxis.musicSubjects(forShelf: key).isEmpty else { continue }
                if started >= CatalogShelfSource.shelfConcurrency {
                    for await answered in group {
                        applyMusicShelf(answered, failures: &failures)
                        break
                    }
                    started -= 1
                }
                group.addTask {
                    do {
                        let answer = try await CatalogShelfSource.musicPage(
                            area: area, shelf: key, rows: RowPreview.limit,
                            storedDay: storedDay, keptStock: keptStock,
                            keptIndex: keptIndex)
                        guard case .archive(let docs, let total) = answer else {
                            return (key, [], nil, nil)
                        }
                        return (key, docs, total, nil)
                    } catch {
                        return (key, [], nil, FreeCatalog.failureReason(error))
                    }
                }
                started += 1
            }
            for await answered in group {
                applyMusicShelf(answered, failures: &failures)
            }
        }
        // The twin rule over the browse order, once, after everything has
        // arrived. This door lacked it: an album carrying two genres began
        // two rows identically, which the per-shelf salt alone cannot avoid
        // on a stock too small to rotate.
        shelfStock = CatalogRotation.twinFree(
            shelfStock, order: CatalogGenreAxis.musicShelves.map(\.key),
            previewLimit: RowPreview.limit)
        if !Task.isCancelled { shelvesLoaded = true }
        Logger.library.notice("FREECAT shelves area=\(area.key, privacy: .public) gefuellt=\(shelfStock.count) fehlgeschlagen=\(failures)")
    }

    /// One answered shelf into the surface. Its own function because the cap
    /// consumes answers in TWO places: while filling up, and when draining.
    private func applyMusicShelf(_ answered: (String, [ArchivePopularDoc], Int?, String?),
                                 failures: inout Int) {
        let (key, docs, total, reason) = answered
        if let reason {
            failures += 1
            Logger.library.error("FREECAT shelf=\(key, privacy: .public) area=\(area.key, privacy: .public) FAILED: \(reason, privacy: .public)")
            return
        }
        let kept = CatalogShelfEntries.music(docs)
        guard !kept.isEmpty else { return }
        shelfStock[key] = (kept, total)
    }

    private func loadMore(reset: Bool = false) async {
        // Source off ⇒ no traffic even if the route is still open.
        guard AppStorageKeys.archiveServiceActive else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false }
        isLoading = true
        defer { isLoading = false }
        switch await ArchiveMusicLoader.areaPage(area, rows: pageSize, page: page) {
        case .loaded(let new, let fetched):
            if new.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += new.filter { seen.insert($0.id).inserted }
            page += 1
            if fetched < pageSize { reachedEnd = true }
        case .failed:
            loadFailed = items.isEmpty
        case .cancelled:
            return
        }
    }
}

/// The full page of a genre shelf. The same shape as the Jamendo shelf, and
/// the same QUERY as the preview row before it: the area query plus the
/// shelf's terms.
struct ArchiveMusicShelfPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let areaKey: String
    let shelfKey: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var detailItem: LibraryItem?
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var loadFailed = false
    @State private var page = 1

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]
    private let pageSize = 30

    private var area: ArchiveMusicArea? {
        ArchiveMusicCatalog.all.first { $0.key == areaKey }
    }
    private var title: String {
        CatalogGenreAxis.musicShelves.first { $0.key == shelfKey }?.title ?? shelfKey
    }

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: area?.placeholderSystemImage ?? "opticaldisc",
                        hidesUnstatedRights: area?.statesUniformRights ?? false,
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item,
                                                      coordinator: playerCoordinator,
                                                      pushMusicRoute: { pushRoute($0) })
                            }
                        })
                    .contextMenu {
                        Button { detailItem = item } label: {
                            Label("Details", systemImage: "info.circle")
                        }
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
            } else if items.isEmpty && loadFailed {
                // A failure is not an empty shelf.
                ContentUnavailableView {
                    Label(title, systemImage: "music.note")
                } description: {
                    Text("Could not load the catalog. Check your connection and try again.")
                } actions: {
                    Button("Retry") { Task { await load(reset: true) } }
                }
                .padding(.top, 40)
            }
            Color.clear.frame(height: 1).bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .task { if items.isEmpty { await load(reset: true) } }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    private func load(reset: Bool = false) async {
        guard AppStorageKeys.archiveServiceActive else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        guard let area else { reachedEnd = true; return }
        if reset { page = 1; reachedEnd = false; loadFailed = false; items = [] }
        isLoading = true
        defer { isLoading = false }
        switch await ArchiveMusicLoader.shelfPage(area, shelfKey: shelfKey, rows: pageSize, page: page) {
        case .loaded(let fresh, let fetched):
            if fresh.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += fresh.filter { seen.insert($0.id).inserted }
            page += 1
            if fetched < pageSize { reachedEnd = true }
        case .failed:
            loadFailed = items.isEmpty
        case .cancelled:
            return
        }
    }
}

/// The shellac surface. There is deliberately no undivided view over the
/// whole collection. Safety comes from the inclusion criterion, so there
/// must be no way around it. Each shelf heading is an entry chevron onto its
/// own page.
struct ShellacShelvesPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var rows: [String: [LibraryItem]] = [:]
    @State private var detailItem: LibraryItem?
    @State private var loadFailed = false
    @ObservedObject private var stockService = CatalogStockService.shared

    /// Ten areas IN SERIES over the same endpoint. The wait is worth saying,
    /// and a stored day says nothing because its tiles are already there.
    /// The size and the threshold are the ones the book surfaces use.
    private var showsShelfPlaceholder: Bool {
        rows.isEmpty && !loadFailed
            && CatalogShelfSource.storedDay(surface: ArchiveMusicCatalog.shellacAll.key).isEmpty
            && stockService.stock(ArchiveMusicCatalog.shellacAll.key) == nil
            && CatalogShelfSource.showsLoadingPlaceholder(
                surface: ArchiveMusicCatalog.shellacAll.key)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                Text("Digitised 78 rpm records from the Internet Archive, separate from your own library. The recording year is the only rights information the source states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                ArchiveRightsNote()
                CatalogStockNotice(
                    state: stockService.state(ArchiveMusicCatalog.shellacAll.key),
                    collection: String(localized: "Old Records"))
                // A failed load says so and offers a retry. A
                // caption-only page would read as "nothing here".
                if rows.values.allSatisfy(\.isEmpty), loadFailed {
                    ContentUnavailableView {
                        Label("Old Records", systemImage: "opticaldisc.fill")
                    } description: {
                        Text("Could not load the catalog. Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { rows = [:]; loadFailed = false; await loadShelves() } }
                    }
                }
                // The same order as everywhere: the popular row on top with
                // a chevron, the nine shelves below it. The parent query has
                // the SAME basis as the shelves (georgeblood), otherwise the
                // row would be a second truth.
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Popular",
                                     destination: MusicRoute.archiveMusicPopular(
                                        ArchiveMusicCatalog.shellacAll.key))
                        .catalogShuffle(area: ArchiveMusicCatalog.shellacAll,
                                        coordinator: playerCoordinator)
                    if let beliebt = rows[ArchiveMusicCatalog.shellacAll.key], !beliebt.isEmpty {
                        tileRow(beliebt, shelf: ArchiveMusicCatalog.shellacAll)
                    } else if showsShelfPlaceholder {
                        // The bare spinner YIELDS to the placeholder instead
                        // of standing beside it. Two loading indicators on one
                        // surface would be two truths about the same wait.
                        ShelfPlaceholderRow(title: String(localized: "Popular"))
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                ForEach(ArchiveMusicCatalog.shellacShelves) { shelf in
                    if let items = rows[shelf.key], !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeading.entry(verbatim: shelf.title,
                                             destination: MusicRoute.archiveMusic(shelf))
                                .catalogShuffle(area: shelf, coordinator: playerCoordinator)
                            tileRow(items, shelf: shelf)
                        }
                    }
                }
                // The nine shelves arrive one by one over a pass that is long
                // enough to be worth saying. Same rule, same component.
                if showsShelfPlaceholder {
                    ShelfPlaceholderRow(title: String(localized: "Loading genres…"))
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Old Records"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let stockTask: Void = CatalogStockService.shared.ensureStock(
                surface: ArchiveMusicCatalog.shellacAll.key,
                archiveQuery: ArchiveMusicCatalog.shellacAll.query)
            await loadShelves()
            await stockTask
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    private func tileRow(_ items: [LibraryItem], shelf: ArchiveMusicArea) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    // For MUSIC the tap plays. On a book it leads into the
                    // detail, on a three-minute track straight into
                    // playback. The player carries the ToS attribution, not
                    // only the sheet.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: shelf.placeholderSystemImage,
                        hidesUnstatedRights: shelf.statesUniformRights,
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .cardRowSlot(spacing: 14)
                    .contextMenu {
                        Button {
                            detailItem = item
                        } label: { Label("Details", systemImage: "info.circle") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func loadShelves() async {
        guard rows.isEmpty else { return }
        guard AppStorageKeys.archiveServiceActive else { return }
        // The parent query runs along. It is the popular row and shares the
        // shelves' basis.
        for shelf in [ArchiveMusicCatalog.shellacAll] + ArchiveMusicCatalog.shellacShelves {
            do {
                // A day page of its own per surface, so the popular row does
                // not begin identically to a shelf.
                let page = CatalogRotation.page(total: shelf.measuredTotal, rowSize: 12,
                                                on: Date(),
                                                salt: CatalogRotation.salt(forShelf: shelf.key))
                // Ten areas in series, once per visit. Through the day store
                // it is ten per day, and the series needs no cap.
                let docs = try await CatalogShelfSource.areaPopular(
                    area: shelf, rows: 12, page: page,
                    storedDay: CatalogShelfSource.storedDay(surface: shelf.key))
                Logger.library.notice("FREECAT \(shelf.key, privacy: .public) loaded=\(docs.count)")
                rows[shelf.key] = CatalogShelfEntries.music(docs)
            } catch {
                guard !error.isCancellation else { return }
                Logger.library.error("FREECAT \(shelf.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
        // The sibling door of the genre shelves gets the same twin rule: a
        // recording tagged with two genres must not begin two rows. The
        // popular row stays outside, as on the book pages; its own salt
        // already separates it.
        rows = CatalogRotation.twinFree(
            rows, order: ArchiveMusicCatalog.shellacShelves.map(\.key),
            previewLimit: 12)
    }
}
