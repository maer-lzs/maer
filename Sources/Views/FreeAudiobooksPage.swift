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
    /// 1790dda: the endless browsing of the LibriVox popularity list — its
    /// own page, so the overview stays an overview.
    case allPopular
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
    /// 0ce5df3: Project Gutenberg audiobooks (own source, own section).
    @State private var gutenberg: [LibraryItem] = []
    /// bca2d20: licensed audiobooks on archive.org outside LibriVox.
    @State private var archiveBooks: [LibraryItem] = []

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
    ///
    /// 1790dda: a section WITHOUT genre data stays visible when a shelf is
    /// chosen instead of emptying itself. Measured in the code: none of the
    /// sources fills `genres` today (LibriVox included) — filtering them all
    /// would have made the page emptier the more precisely one chooses, which
    /// is the worst of the possible behaviours. Where the data arrives later,
    /// the filter starts working on its own.
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
                        // 1790dda: the page carries THREE sources with two
                        // different rights bases now — the old sentence named
                        // only LibriVox and claimed public domain for all.
                        Text("Free audiobooks from LibriVox, Project Gutenberg and the Internet Archive — public domain or openly licensed, separate from your own library.")
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
                            RowHeading.plain("New at LibriVox")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(RowPreview.cut(onShelf(newBooks))) { item in
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
                        // 1790dda: "Popular" WAS an endless grid in the MIDDLE
                        // of the page — it grew while scrolling and buried
                        // everything below it, so the two new sources were
                        // practically unreachable. This page is an overview of
                        // THREE sources, not the endless catalogue of one:
                        // the row is horizontal like its neighbours now, and
                        // full browsing moved to its own page (the pattern the
                        // audiobook tab already uses).
                        if !popular.isEmpty {
                            HStack {
                                Text("Popular at LibriVox").font(.title3).bold()
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
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(RowPreview.cut(onShelf(popular))) { item in
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
                        // bca2d20: audiobooks on archive.org OUTSIDE LibriVox
                        // — own section with the licence visible per title
                        // (they are CC-licensed, not public domain).
                        if !archiveBooks.isEmpty {
                            // 1790dda: name the SOURCE like the neighbouring
                            // section does — "More free audiobooks" read like
                            // a leftovers bin.
                            RowHeading.plain(verbatim: "Internet Archive")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(RowPreview.cut(onShelf(archiveBooks))) { item in
                                        FreeCatalogBookTile(
                                            item: item,
                                            onTap: { Task { await playerCoordinator.open(item: item) } })
                                        .containerRelativeFrame(
                                            .horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                        // 0ce5df3: Project Gutenberg — own section, because it
                        // is a different source with its own rights basis
                        // (public domain, no conditions) and its own naming.
                        if !gutenberg.isEmpty {
                            // Eigenname, nicht übersetzbar (verbatim-Klasse) —
                            // und die Quellennennung, die der Auftrag verlangt.
                            RowHeading.plain(verbatim: "Project Gutenberg")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(RowPreview.cut(onShelf(gutenberg))) { item in
                                        FreeCatalogBookTile(
                                            item: item,
                                            onTap: { Task { await playerCoordinator.open(item: item) } })
                                        .containerRelativeFrame(
                                            .horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
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
        .task { await loadGutenberg() }
        .task { await loadArchiveBooks() }
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

    /// 0ce5df3: two pages are plenty for a row — the stock is 1.124 books,
    /// but a shelf that never ends is not better than one that fits.
    private func loadGutenberg() async {
        guard gutenberg.isEmpty else { return }
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true
        else { return }
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        let languages = SuggestionLanguages.current()
        var books: [GutenbergClient.Book] = []
        for page in 1...2 {
            guard let hit = try? await GutenbergClient.audiobooks(languages: languages, page: page)
            else {
                Logger.library.notice("FREECAT gutenberg page=\(page) FAILED")
                break
            }
            books += hit
            if hit.isEmpty { break }
        }
        let provider = FreeCatalogProvider.shared
        let items = books.compactMap { provider.remember(gutenberg: $0) }
        Logger.library.notice("FREECAT gutenberg langs=\(languages.joined(separator: ","), privacy: .public) loaded=\(books.count) shown=\(items.count)")
        gutenberg = items
    }

    private func loadArchiveBooks() async {
        guard archiveBooks.isEmpty else { return }
        guard UserDefaults.standard.object(forKey: AppStorageKeys.freeCatalogsMasterEnabled) as? Bool ?? true,
              UserDefaults.standard.object(forKey: AppStorageKeys.archivePopularEnabled) as? Bool ?? true
        else { return }
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        let languages = SuggestionLanguages.current()
        guard let docs = try? await ArchiveOrgClient.audiobooksOutsideLibriVox(
            rows: 12, languageCodes: languages) else {
            Logger.library.notice("FREECAT archive-books FAILED")
            return
        }
        let provider = FreeCatalogProvider.shared
        let items = docs.compactMap { provider.remember(popular: $0) }
        Logger.library.notice("FREECAT archive-books langs=\(languages.joined(separator: ","), privacy: .public) loaded=\(docs.count) shown=\(items.count)")
        archiveBooks = items
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
                // 6fcb301 Nachzug: was die Reihe zeigt, entscheidet EINE Konstante —
                // diese 12 stand hier zufaellig daneben.
                newBooks = filtered.prefix(RowPreview.limit).map { provider.remember(book: $0) }
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
