// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// b6150a4: the SEPARATE "Free Audiobooks" area for the audiobooks tab
/// (Katalog ≠ Bibliothek, the classical-area pattern): "New at LibriVox" as
/// a horizontal row plus a popularity GRID (archive.org, language-filtered
/// server-side via the suggestion languages), external-catalog header line,
/// details sheet with PD badge + takeover menu. Reached from the Home teaser
/// titles and (after the owner's picture choice) the tab entry.
nonisolated enum FreeAudiobooksRoute: Hashable {
    case area
}

struct FreeAudiobooksPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var newBooks: [LibraryItem] = []
    @State private var popular: [LibraryItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            if newBooks.isEmpty && popular.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if newBooks.isEmpty && popular.isEmpty {
                if loadFailed {
                    ContentUnavailableView {
                        Label("Free Audiobooks", systemImage: "book.closed")
                    } description: {
                        Text("Could not load the catalog. Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await load(reset: true) } }
                    }
                } else {
                    ContentUnavailableView("Free Audiobooks", systemImage: "book.closed")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                        Text("Free public-domain audiobooks from LibriVox — separate from your own library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        if !newBooks.isEmpty {
                            Text("New at LibriVox").font(.title3).bold().padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(newBooks) { item in
                                        tile(item)
                                            .containerRelativeFrame(.horizontal,
                                                                    count: CardMetrics.recommendationColumns(regularWidth: false),
                                                                    spacing: 14)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                        if !popular.isEmpty {
                            Text("Popular").font(.title3).bold().padding(.horizontal)
                            CoverGrid(columns: columns) {
                                ForEach(popular) { item in
                                    tile(item)
                                        .onAppear {
                                            if item.id == popular.last?.id { Task { await load() } }
                                        }
                                }
                            }
                            .padding(.horizontal)
                        }
                        if isLoading && !(newBooks.isEmpty && popular.isEmpty) {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Free Audiobooks"))
        .task { if newBooks.isEmpty && popular.isEmpty { await load(reset: true) } }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func tile(_ item: LibraryItem) -> some View {
        MediaTile(
            title: item.title,
            subtitle: item.author,
            coverURL: AppSession.shared.coverURL(forItemId: item.id),
            placeholderSystemImage: "book.closed",
            // ea6e002: same card language as the rows and the library.
            meta: bookTimeLine(progress: nil, duration: item.media?.duration),
            titleLineLimit: 1,
            onTap: { Task { await playerCoordinator.open(item: item) } },
            // fbcff9f: same corner ring as every other download surface.
            corner: { FreeCatalogImportBadge(itemId: item.id) }
        )
        .contextMenu {
            Button {
                detailItem = item
            } label: { Label("Details", systemImage: "info.circle") }
        }
    }

    private func load(reset: Bool = false) async {
        // 5034add: master off ⇒ no traffic even if the route is still open.
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true else { return }
        guard !isLoading, !reachedEnd || reset else { return }
        if reset { page = 1; reachedEnd = false; loadFailed = false }
        isLoading = true
        defer { isLoading = false }
        let provider = FreeCatalogProvider.shared
        let codes = SuggestionLanguages.current()
        if reset {
            do {
                let books = try await LibriVoxClient.newBooks(sinceDays: 120, limit: 40)
                let filtered = FreeCatalog.filterByLanguages(books, codes: codes)
                Logger.library.notice("FREECAT area-new loaded=\(books.count) filtered=\(filtered.count)")
                newBooks = filtered.prefix(12).map { provider.remember(book: $0) }
            } catch {
                Logger.library.error("FREECAT area-new FAILED: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            // 938aebc: per-language popularity, interleaved — the combined
            // clause let English bury every other language.
            let docs = try await ArchiveOrgClient.popularLibriVoxByLanguage(
                rowsPerLanguage: pageSize, languageCodes: codes, limit: pageSize, page: page)
            Logger.library.notice("FREECAT area-popular page=\(page) sort=downloads codes=\(codes.isEmpty ? "-" : codes.joined(separator: ","), privacy: .public) loaded=\(docs.count)")
            let new = docs.compactMap { provider.remember(popular: $0) }
            if new.isEmpty { reachedEnd = true } else {
                var seen = Set(popular.map(\.id))
                popular += new.filter { seen.insert($0.id).inserted }
                page += 1
                if docs.count < pageSize { reachedEnd = true }
            }
        } catch {
            Logger.library.error("FREECAT area-popular FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = newBooks.isEmpty && popular.isEmpty
        }
    }
}
