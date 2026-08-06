// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// Paket 3 (11be262/9ef73a4): THE one parameterised source page — every
/// catalog row's chevron lands here. Fundgrube with staged paging (the page IS
/// the target surface, so no preview cap — 6fcb301 Punkt 5), ordered by the
/// axis that CARRIES for this source:
///
///   LibriVox / Gutenberg → genre chips (ONE axis, Regel 2 — the LCSH
///     spellings extend `CatalogGenreAxis`, no second axis next to it)
///   Internet Archive → NO chips (subjects are collection boilerplate,
///     measured: "livres audio gratuits", "mp3", "learn french")
///   Old Time Radio → no chips (series bundles are the unit)
///   Feed sources → the curated rows, complete (no paging — the stock IS the
///     curation)
///
/// G8 for chips: only shelves the LOADED stock fills appear — an empty chip
/// is an affordance without a target.
struct CatalogSourcePage: View {
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared

    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?
    @State private var selectedShelf: String?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    /// Chips only where the axis carries (measured per source, 9ef73a4).
    private var hasChips: Bool { source == .librivox || source == .gutenberg }

    private func genres(of item: LibraryItem) -> [String] {
        item.media?.metadata?.genres ?? []
    }

    /// Which shelves the loaded stock fills — via the source's OWN spelling
    /// family (LibriVox genre names vs. Gutenberg LCSH subjects).
    private var shelves: [(key: String, title: String)] {
        guard hasChips else { return [] }
        var present = Set<String>()
        for item in items {
            for shelf in shelvesOf(item) { present.insert(shelf) }
        }
        return CatalogGenreAxis.librivoxShelves.filter { present.contains($0.key) }
    }

    private func shelvesOf(_ item: LibraryItem) -> [String] {
        source == .gutenberg
            ? CatalogGenreAxis.shelves(forSubjects: genres(of: item))
            : CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: item))
    }

    /// The visible cut: everything, or one shelf. An item WITHOUT genre data
    /// stays visible (1790dda rule — unknown is not "does not match").
    private func onShelf(_ items: [LibraryItem]) -> [LibraryItem] {
        guard let selectedShelf else { return items }
        return items.filter {
            let shelves = shelvesOf($0)
            return shelves.isEmpty || shelves.contains(selectedShelf)
        }
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
            if items.isEmpty {
                // Seed from the overview's already-loaded preview so the page
                // opens filled, then page onward from the network.
                items = seedItems()
                await load()
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// A feed source: all curated rows, complete — the curation IS the stock.
    private var feedList: some View {
        LazyVStack(spacing: 0) {
            ForEach(source.curatedFeeds(forLanguages: SuggestionLanguages.current())) { entry in
                CatalogFeedRow(result: PodcastSearchResult(
                    title: entry.title, author: entry.author,
                    artworkURL: nil, feedURL: entry.feedURL))
            }
        }
        .padding(.top, TabContentLayout.topInset)
    }

    private var catalogGrid: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            // 9ef73a4/48e786d: the chips moved HERE from the overview — the
            // control sits on the surface it acts on (same rule as sorting).
            if !shelves.isEmpty { shelfRow }
            // LibriVox keeps its "new additions" as a second lens on the
            // same source — the overview shows one row per source only.
            if source == .librivox, !store.sourceRows.librivoxNew.isEmpty {
                RowHeading.plain("New at LibriVox")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(RowPreview.cut(store.sourceRows.librivoxNew)) { item in
                            tile(item)
                                .containerRelativeFrame(.horizontal,
                                                        count: CardMetrics.recommendationColumns(regularWidth: false),
                                                        spacing: 14)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
                RowHeading.plain("Popular")
            }
            CoverGrid(columns: columns) {
                ForEach(onShelf(items)) { item in
                    tile(item)
                        .onAppear {
                            if item.id == items.last?.id { Task { await load() } }
                        }
                }
            }
            .padding(.horizontal)
            if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
        }
        .padding(.top, TabContentLayout.topInset)
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

    private func tile(_ item: LibraryItem) -> some View {
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: source == .oldTimeRadio ? "waveform.and.mic" : "book.closed",
            onTap: { Task { await playerCoordinator.open(item: item) } }
        )
        .contextMenu {
            Button { detailItem = item } label: {
                Label("Details", systemImage: "info.circle")
            }
        }
    }

    private func seedItems() -> [LibraryItem] {
        switch source {
        case .librivox:     store.sourceRows.librivoxPopular
        case .archiveBooks: store.sourceRows.archiveBooks
        case .gutenberg:    store.sourceRows.gutenberg
        case .oldTimeRadio: store.sourceRows.oldTimeRadio
        default:            []
        }
    }

    private func load() async {
        guard !source.isFeedBased, !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        #if DEBUG
        if UITestSeed.isActive { reachedEnd = true; return }
        #endif
        let provider = FreeCatalogProvider.shared
        let codes = SuggestionLanguages.current()
        var new: [LibraryItem] = []
        switch source {
        case .librivox:
            guard let docs = try? await ArchiveOrgClient.popularLibriVoxByLanguage(
                rowsPerLanguage: pageSize, languageCodes: codes, limit: pageSize, page: page)
            else { reachedEnd = true; return }
            new = docs.compactMap { provider.remember(popular: $0) }
            if docs.count < pageSize { reachedEnd = true }
        case .archiveBooks:
            guard let docs = try? await ArchiveOrgClient.audiobooksOutsideLibriVox(
                rows: pageSize, languageCodes: codes, page: page)
            else { reachedEnd = true; return }
            new = docs.compactMap { provider.remember(popular: $0) }
            if docs.count < pageSize { reachedEnd = true }
        case .gutenberg:
            // gutendex pages at 32; same language-fallback rule as the row.
            var books = (try? await GutenbergClient.audiobooks(languages: codes, page: page)) ?? []
            if books.isEmpty, page == 1, !codes.isEmpty {
                books = (try? await GutenbergClient.audiobooks(languages: [], page: 1)) ?? []
            }
            new = books.compactMap { provider.remember(gutenberg: $0) }
            if books.isEmpty { reachedEnd = true }
        case .oldTimeRadio:
            guard let docs = try? await ArchiveOrgClient.popularOldTimeRadio(
                rows: pageSize, page: page)
            else { reachedEnd = true; return }
            new = docs.compactMap { doc in
                guard let identifier = doc.identifier else { return nil }
                provider.rememberOldTimeRadio(identifier)
                return provider.remember(popular: doc)
            }
            if docs.count < pageSize { reachedEnd = true }
        default:
            reachedEnd = true
        }
        var seen = Set(items.map(\.id))
        items += new.filter { seen.insert($0.id).inserted }
        page += 1
        if new.isEmpty { reachedEnd = true }
        Logger.library.notice("FREECAT page source=\(source.rawValue, privacy: .public) page=\(page) items=\(items.count)")
    }
}
