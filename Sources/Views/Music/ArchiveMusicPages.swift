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
    /// Bestand je Fach. Dieselbe Konstruktion wie `CatalogShelfSource`:
    /// ein Fach erscheint, weil die QUELLE es hat.
    @State private var shelfStock: [String: (items: [LibraryItem], total: Int?)] = [:]
    @State private var shelvesLoaded = false
    @State private var shelvesLoading = false

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
                        // Dieselbe Ordnung wie auf den Katalogseiten: die
                        // Beliebt-Reihe steht OBEN als Kachelreihe mit
                        // Chevron, die Faecher darunter. Das
                        // endlose Nachladen lebt auf der Vollseite hinter dem
                        // Chevron weiter. Dort, wo Scrollen die Form ist.
                        if area.hasGenreShelves {
                            popularRow
                            ForEach(genreShelves, id: \.key) { shelf in
                                genreRow(shelf)
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
            async let shelvesTask: Void = loadShelves()
            if items.isEmpty { await loadMore(reset: true) }
            await shelvesTask
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// Dieselbe Form wie `CatalogSourcePage.popularRow`. Benannte Reihe
    /// mit Chevron, das endlose Nachladen auf der Vollseite dahinter.
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

    /// Ein Fach erscheint nur, wenn die Quelle es fuellt.
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

    /// Je Fach den BESTAND fragen (dieselbe
    /// Abfrage wie die Vollseite), Tor NACH dem Lauf buchen, Abbruch oeffnet
    /// wieder, und ein Fehlschlag ist eine Antwort statt eines leeren Fachs.
    private func loadShelves() async {
        guard area.hasGenreShelves, !shelvesLoaded, !shelvesLoading else { return }
        guard AppStorageKeys.freeCatalogsMasterActive else { return }
        shelvesLoading = true
        defer { shelvesLoading = false }
        let provider = FreeCatalogProvider.shared
        let base = area.query
        var failures = 0
        await withTaskGroup(of: (String, [ArchivePopularDoc], Int?, String?).self) { group in
            for shelf in CatalogGenreAxis.musicShelves {
                let key = shelf.key
                let terms = CatalogGenreAxis.musicSubjects(forShelf: key)
                guard !terms.isEmpty else { continue }
                group.addTask {
                    // Kein Deckel. Bei `subject:` ist ein laengeres ODER
                    // schlicht mehr Bestand (gemessen: Faktor 9 fuer 0,05 s).
                    let clause = terms.map { "subject:\"\($0)\"" }
                        .joined(separator: " OR ")
                    do {
                        let hit = try await ArchiveOrgClient.popularWithTotal(
                            query: "\(base) AND (\(clause))", rows: RowPreview.limit)
                        return (key, hit.docs, hit.total, nil)
                    } catch {
                        return (key, [], nil, FreeCatalog.failureReason(error))
                    }
                }
            }
            for await (key, docs, total, reason) in group {
                if let reason {
                    failures += 1
                    Logger.library.error("FREECAT shelf=\(key, privacy: .public) area=\(area.key, privacy: .public) FAILED: \(reason, privacy: .public)")
                    continue
                }
                let kept = docs.compactMap { provider.remember(popular: $0) }
                guard !kept.isEmpty else { continue }
                shelfStock[key] = (kept, total)
            }
        }
        if !Task.isCancelled { shelvesLoaded = true }
        Logger.library.notice("FREECAT shelves area=\(area.key, privacy: .public) gefuellt=\(shelfStock.count) fehlgeschlagen=\(failures)")
    }

    private func loadMore(reset: Bool = false) async {
        // Master off ⇒ no traffic even if the route is still open.
        guard AppStorageKeys.freeCatalogsMasterActive else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false }
        isLoading = true
        defer { isLoading = false }
        do {
            let docs = try await ArchiveOrgClient.popularMusic(area: area, rows: pageSize, page: page)
            Logger.library.notice("FREECAT \(area.key, privacy: .public) page=\(page) loaded=\(docs.count)")
            let provider = FreeCatalogProvider.shared
            let new = docs.compactMap { provider.remember(popular: $0) }
            if new.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += new.filter { seen.insert($0.id).inserted }
            page += 1
            if docs.count < pageSize { reachedEnd = true }
        } catch {
            guard !error.isCancellation else { return }
            Logger.library.error("FREECAT \(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = items.isEmpty
        }
    }
}

/// Die Vollseite eines Genre-Fachs. Dieselbe Form wie das Jamendo-Fach. Und
/// dieselbe ABFRAGE wie die Vorschau-Reihe davor: Bereichs-Abfrage plus die
/// Begriffe des Fachs.
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
                // Ein Fehlschlag ist kein leeres Fach.
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
        }
    }

    private func load(reset: Bool = false) async {
        guard AppStorageKeys.freeCatalogsMasterActive else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        guard let area else { reachedEnd = true; return }
        if reset { page = 1; reachedEnd = false; loadFailed = false; items = [] }
        isLoading = true
        defer { isLoading = false }
        let terms = CatalogGenreAxis.musicSubjects(forShelf: shelfKey)
        guard !terms.isEmpty else { reachedEnd = true; return }
        let clause = terms.map { "subject:\"\($0)\"" }.joined(separator: " OR ")
        do {
            let docs = try await ArchiveOrgClient.popularArchiveMusic(
                query: "\(area.query) AND (\(clause))", rows: pageSize, page: page)
            let provider = FreeCatalogProvider.shared
            let fresh = docs.compactMap { provider.remember(popular: $0) }
            if fresh.isEmpty { reachedEnd = true; return }
            var seen = Set(items.map(\.id))
            items += fresh.filter { seen.insert($0.id).inserted }
            page += 1
            if docs.count < pageSize { reachedEnd = true }
        } catch {
            guard !error.isCancellation else { return }
            Logger.library.error("FREECAT shelf=\(shelfKey, privacy: .public) area=\(areaKey, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = items.isEmpty
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                Text("Digitised 78 rpm records from the Internet Archive — separate from your own library. The recording year is the only rights information the source states.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                ArchiveRightsNote()
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
                // Dieselbe Ordnung wie ueberall: die Beliebt-Reihe oben mit
                // Chevron, die neun Faecher darunter. Die Eltern-Abfrage hat
                // DIESELBE Grundlage wie die Faecher (georgeblood), sonst
                // waere die Reihe eine zweite Wahrheit.
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Popular",
                                     destination: MusicRoute.archiveMusicPopular(
                                        ArchiveMusicCatalog.shellacAll.key))
                    if let beliebt = rows[ArchiveMusicCatalog.shellacAll.key], !beliebt.isEmpty {
                        tileRow(beliebt, shelf: ArchiveMusicCatalog.shellacAll)
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
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Old Records"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadShelves() }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func tileRow(_ items: [LibraryItem], shelf: ArchiveMusicArea) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    // Bei MUSIK spielt der Tap: beim Buch fuehrt er ins
                    // Detail, beim Dreiminueter direkt in die Wiedergabe.
                    // Die ToS-Attribution traegt der Player, nicht nur das
                    // Sheet.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: shelf.placeholderSystemImage,
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
        guard AppStorageKeys.freeCatalogsMasterActive else { return }
        let provider = FreeCatalogProvider.shared
        // Die Eltern-Abfrage laeuft mit. Sie ist die Beliebt-Reihe und
        // teilt die Grundlage der Faecher.
        for shelf in [ArchiveMusicCatalog.shellacAll] + ArchiveMusicCatalog.shellacShelves {
            do {
                // Je Flaeche eine eigene Tagesseite, damit die
                // Beliebt-Reihe nicht mit einem Fach identisch beginnt.
                let page = CatalogRotation.page(total: shelf.measuredTotal, rowSize: 12,
                                                on: Date(),
                                                salt: CatalogRotation.salt(forShelf: shelf.key))
                let docs = try await ArchiveOrgClient.popularMusic(area: shelf, rows: 12, page: page)
                Logger.library.notice("FREECAT \(shelf.key, privacy: .public) loaded=\(docs.count)")
                rows[shelf.key] = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                guard !error.isCancellation else { return }
                Logger.library.error("FREECAT \(shelf.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
    }
}
