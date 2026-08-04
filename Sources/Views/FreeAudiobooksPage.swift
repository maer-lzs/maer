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

    @Environment(\.pushPodcastRoute) private var pushPodcastRoute
    @State private var selectedShelf: String?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    /// The shelves the CURRENT stock fills (empty chips would be a lie).
    private var shelves: [(key: String, title: String)] {
        var present = Set<String>()
        for item in popular + newBooks {
            for shelf in CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: item)) {
                present.insert(shelf)
            }
        }
        return CatalogGenreAxis.librivoxShelves.filter { present.contains($0.key) }
    }

    private func genres(of item: LibraryItem) -> [String] {
        item.media?.metadata?.genres ?? []
    }

    /// The visible cut: everything, or one shelf.
    private func onShelf(_ items: [LibraryItem]) -> [LibraryItem] {
        guard let selectedShelf else { return items }
        return items.filter {
            CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: $0)).contains(selectedShelf)
        }
    }

    private var shelfRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfChip(key: nil, title: String(localized: "All"))
                ForEach(shelves, id: \.key) { shelf in
                    shelfChip(key: shelf.key, title: shelf.title)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func shelfChip(key: String?, title: String) -> some View {
        let selected = selectedShelf == key
        let fill: AnyShapeStyle = selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selectedShelf = key }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(fill, in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("freebooks-shelf-\(key ?? "all")")
    }

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
                        // 8d49a8e: the genre axis. LibriVox mixes genre and
                        // EPOCH in one field ("Published 1800-1900") — the
                        // pure mapping drops the epochs, so no year stands
                        // between the shelves. Shelves appear only when the
                        // loaded stock actually fills them (no empty chips).
                        if !shelves.isEmpty { shelfRow }
                        if !newBooks.isEmpty {
                            Text("New at LibriVox").font(.title3).bold().padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(onShelf(newBooks)) { item in
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
                                ForEach(onShelf(popular)) { item in
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
                        // 8d49a8e: cross-link to the other catalog page (G8 —
                        // the target exists and is reachable from here).
                        Button {
                            pushPodcastRoute(.hoerspiele)
                        } label: {
                            HStack {
                                Label("Also interesting: Radio Plays", systemImage: "waveform.and.mic")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("freebooks-crosslink")
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
        FreeCatalogBookTile(
            item: item,
            onTap: { Task { await playerCoordinator.open(item: item) } }
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
