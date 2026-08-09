// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// 50f4751 → parameterised: THE page for every archive.org music area
/// (classical · netlabels · the 78 rpm genre shelves). External free catalog,
/// clearly marked as such (header line + licence capsule/detail sheet);
/// NEVER mixed into the personal library surfaces. Popularity-sorted grid
/// (archive.org downloads), paged; tiles play directly, context menu opens
/// the licence sheet.
///
/// Regel 2: there is no second page of this shape — the area carries what
/// differs (query, title, note, symbol).
struct ArchiveMusicPage: View {
    let area: ArchiveMusicArea
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?

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
                        CoverGrid(columns: columns) {
                            ForEach(items) { item in
                                // Shared catalog tile (Regel 2): carries the
                                // licence capsule (40b8f96) — which is what
                                // makes the CC-licensed netlabel releases
                                // honest at a glance.
                                FreeCatalogBookTile(
                                    item: item,
                                    placeholderSystemImage: area.placeholderSystemImage,
                                    onTap: { Task { await playerCoordinator.open(item: item) } }
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
        .task { if items.isEmpty { await loadMore(reset: true) } }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func loadMore(reset: Bool = false) async {
        // 5034add: master off ⇒ no traffic even if the route is still open.
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else { return }
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
            Logger.library.error("FREECAT \(area.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = items.isEmpty
        }
    }
}

/// „Alte Schallplatten": the shelves ARE the surface. There is deliberately
/// no undivided view over the whole collection — safety comes from the
/// inclusion criterion, so there must be no way around it (the reviewer 08.08.,
/// Auflage 1). Each shelf heading is an entry chevron onto its own page.
struct ShellacShelvesPage: View {
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
                // Regel 3: a failed load says so and offers a retry — a
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
                    // M1 (09.08.): bei MUSIK spielt der Tap. Die Regel ist
                    // dieselbe wie bei den Buechern, nur die Frage ist eine
                    // andere: beim Buch fragt man „was ist das?" (→ Detail),
                    // beim Dreiminueter „spiel" (→ Wiedergabe). Spiegelbildlich
                    // und trotzdem konsistent — bitte nicht als Inkonsistenz
                    // „aufraeumen". Die ToS-Attribution traegt jetzt der Player
                    // (`player-zur-quellseite`), nicht mehr nur das Sheet.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: shelf.placeholderSystemImage,
                        onTap: { Task { await playerCoordinator.open(item: item) } })
                    .containerRelativeFrame(.horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
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
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else { return }
        let provider = FreeCatalogProvider.shared
        for shelf in ArchiveMusicCatalog.shellacShelves {
            do {
                let page = CatalogRotation.page(total: shelf.measuredTotal, rowSize: 12, on: Date())
                let docs = try await ArchiveOrgClient.popularMusic(area: shelf, rows: 12, page: page)
                Logger.library.notice("FREECAT \(shelf.key, privacy: .public) loaded=\(docs.count)")
                rows[shelf.key] = docs.compactMap { provider.remember(popular: $0) }
            } catch {
                Logger.library.error("FREECAT \(shelf.key, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
        }
    }
}
