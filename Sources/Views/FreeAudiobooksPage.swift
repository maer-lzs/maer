// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// b6150a4 → 11be262: the ONE merged catalog page — "Freie Hörbücher &
/// Hörspiele". Radio-play feeds and public-domain catalogs share the surface;
/// the German split Hörspiel/Hörbuch is not one the directories know, so the
/// SOURCE is the ordering axis (one row per source, 733ac2a). The ACTION
/// carries the remaining distinction: feed rows subscribe, catalog tiles play.
nonisolated enum FreeAudiobooksRoute: Hashable {
    case area
    /// 1790dda: the endless browsing of the LibriVox popularity list — its
    /// own page, so the overview stays an overview.
    case allPopular
}

/// Paket 2: the ONE feed row of the catalog surfaces — show-preview push +
/// subscribe badge. Shared with the old radio-play page until Paket 4 removes
/// it (Regel 2: one component, not a copy).
struct CatalogFeedRow: View {
    let result: PodcastSearchResult
    @Environment(\.pushPodcastRoute) private var pushRoute

    var body: some View {
        Button {
            pushRoute(.showPreview(feedURL: result.feedURL))
        } label: {
            HStack(spacing: 8) {
                MediaRowContent(
                    coverURL: result.artworkURL.flatMap { URL(string: $0) },
                    eyebrow: result.author,
                    title: result.title,
                    meta: String(localized: "Podcast"),
                    placeholderSystemImage: "waveform.and.mic",
                    // c125ccd: a hit without artwork resolves it from the feed.
                    coverOverride: result.artworkURL == nil
                        ? FeedArtwork(feedURL: result.feedURL, placeholderSystemImage: "waveform.and.mic")
                        : nil
                )
                PodcastSubscribeBadge(feedURL: result.feedURL)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FreeAudiobooksPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Paket 1: the load layer lives in the store — one pass, all catalog
    /// sources, one visible failure per source. The page renders dumb.
    @ObservedObject private var store = FreeCatalogStore.shared
    @State private var detailItem: LibraryItem?
    @State private var selectedShelf: String?
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    private var rows: CatalogSourceLoader.SourceRows { store.sourceRows }
    private var languages: [String] { SuggestionLanguages.current() }

    /// The shelves the CURRENT stock fills (empty chips would be a lie).
    /// Kept for Paket 3 (chips move to the source pages, b2b84ef: keep, don't
    /// rebuild) — source is the store now.
    private var shelves: [(key: String, title: String)] {
        var present = Set<String>()
        for item in rows.librivoxPopular + rows.librivoxNew {
            for shelf in CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: item)) {
                present.insert(shelf)
            }
        }
        return CatalogGenreAxis.librivoxShelves.filter { present.contains($0.key) }
    }

    private func genres(of item: LibraryItem) -> [String] {
        item.media?.metadata?.genres ?? []
    }

    /// The visible cut: everything, or one shelf (see shelves — Paket 3 home).
    private func onShelf(_ items: [LibraryItem]) -> [LibraryItem] {
        guard let selectedShelf else { return items }
        let withGenres = items.filter { !genres(of: $0).isEmpty }
        guard !withGenres.isEmpty else { return items }
        return items.filter {
            let shelves = CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: $0))
            return shelves.isEmpty || shelves.contains(selectedShelf)
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

    private var catalogRowsEmpty: Bool {
        rows.librivoxPopular.isEmpty && rows.archiveBooks.isEmpty
            && rows.gutenberg.isEmpty && rows.oldTimeRadio.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // The rights bases differ per source — the capsule per title
                // says which; this line only names the FAMILIES.
                Text("Free radio plays and audiobooks — public broadcasters, independent audio drama and public-domain catalogs, separate from your own library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                // the reviewer's Reihenfolge (11be262): feeds first, catalogs after —
                // the feed rows are static curation and render instantly.
                feedSection(.oerr)
                feedSection(.escapeArtists)
                feedSection(.usIndies)
                tileSection(.oldTimeRadio, items: rows.oldTimeRadio,
                            placeholder: "waveform.and.mic")
                librivoxSection
                tileSection(.archiveBooks, items: rows.archiveBooks)
                tileSection(.gutenberg, items: rows.gutenberg)
                if !store.sourcesLoaded && catalogRowsEmpty && rows.failures.isEmpty {
                    // Offline: an honest line instead of an eternal spinner —
                    // the load pass never ran, so no failure is recorded.
                    if networkMonitor.isConnected {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else {
                        Text("The catalogs need a connection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Free Audiobooks & Radio Plays"))
        .task { await store.ensureSourcesLoaded() }
        // Connection returns while the page is open: load then.
        .onChange(of: networkMonitor.isConnected) { _, connected in
            if connected { Task { await store.ensureSourcesLoaded() } }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// A feed source: its curated entries as subscribe rows. Rows, not tiles —
    /// the ACTION (subscribe) is the distinction the page keeps (Auflage 4).
    @ViewBuilder
    private func feedSection(_ source: CatalogSource) -> some View {
        let feeds = source.curatedFeeds(forLanguages: languages)
        if !feeds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.plain(verbatim: source.title)
                LazyVStack(spacing: 0) {
                    ForEach(feeds) { entry in
                        CatalogFeedRow(result: PodcastSearchResult(
                            title: entry.title, author: entry.author,
                            artworkURL: nil, feedURL: entry.feedURL))
                    }
                }
            }
        }
    }

    /// A catalog source: preview tile row. An EMPTY row with a recorded
    /// failure shows the reason (Regel 3) instead of silently missing.
    @ViewBuilder
    private func tileSection(_ source: CatalogSource, items: [LibraryItem],
                             placeholder: String = "book.closed") -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.plain(verbatim: source.title)
                tileRow(items, placeholder: placeholder)
            }
        } else if rows.failures.contains(source) {
            VStack(alignment: .leading, spacing: 6) {
                RowHeading.plain(verbatim: source.title)
                Text("Could not load \(source.title). Check your connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    /// LibriVox keeps its established full-list link (a journey holds it).
    @ViewBuilder
    private var librivoxSection: some View {
        if !rows.librivoxPopular.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RowHeading.plain(verbatim: CatalogSource.librivox.title)
                    Spacer()
                    NavigationLink(value: FreeAudiobooksRoute.allPopular) {
                        HStack(spacing: 4) {
                            Text("Show all").font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                    .accessibilityIdentifier("freebooks-show-all")
                }
                .padding(.horizontal)
                tileRow(rows.librivoxPopular, placeholder: "book.closed")
            }
        } else if rows.failures.contains(.librivox) {
            VStack(alignment: .leading, spacing: 6) {
                RowHeading.plain(verbatim: CatalogSource.librivox.title)
                Text("Could not load \(CatalogSource.librivox.title). Check your connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    private func tileRow(_ items: [LibraryItem], placeholder: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(onShelf(items))) { item in
                    tile(item, placeholder: placeholder)
                        .containerRelativeFrame(.horizontal,
                                                count: CardMetrics.recommendationColumns(regularWidth: false),
                                                spacing: 14)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func tile(_ item: LibraryItem, placeholder: String = "book.closed") -> some View {
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: placeholder,
            onTap: { Task { await playerCoordinator.open(item: item) } }
        )
        .contextMenu {
            Button {
                detailItem = item
            } label: { Label("Details", systemImage: "info.circle") }
        }
    }
}

/// 1790dda: the full LibriVox popularity list — endless loading belongs on
/// its OWN page, not in the middle of a three-source overview.
struct FreeAudiobooksAllPopularPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var detailItem: LibraryItem?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    FreeCatalogBookTile(
                        item: item,
                        onTap: { Task { await playerCoordinator.open(item: item) } })
                    .contextMenu {
                        Button { detailItem = item } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                    }
                    .onAppear {
                        if item.id == items.last?.id { Task { await load() } }
                    }
                }
            }
            .padding(.horizontal)
            if isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
        }
        .navigationTitle("Popular at LibriVox")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task { if items.isEmpty { await load() } }
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
        let codes = SuggestionLanguages.current()
        guard let docs = try? await ArchiveOrgClient.popularLibriVoxByLanguage(
            rowsPerLanguage: pageSize, languageCodes: codes, limit: pageSize, page: page)
        else { reachedEnd = true; return }
        let provider = FreeCatalogProvider.shared
        let new = docs.compactMap { provider.remember(popular: $0) }
        var seen = Set(items.map(\.id))
        items += new.filter { seen.insert($0.id).inserted }
        page += 1
        if docs.count < pageSize { reachedEnd = true }
    }
}
