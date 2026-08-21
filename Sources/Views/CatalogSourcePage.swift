// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    let source: CatalogSource
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared

    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var reachedEnd = false
    /// P1: language-fallback as SESSION state (one truth, held here).
    @State private var languageFallback = false
    @State private var detailItem: LibraryItem?
    @State private var selectedShelf: String?

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    /// Chips only where the axis carries (measured per source, 9ef73a4).
    /// P5/P7: the genre scaffolding covers the measured sources — LibriVox,
    /// Gutenberg (H), IA audiobooks (26% shelve) and OTR (40% shelve).
    private var hasChips: Bool {
        source == .librivox || source == .gutenberg
            || source == .archiveBooks || source == .oldTimeRadio
    }

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
        // LibriVox speaks its own genre names; every archive-subject family
        // (Gutenberg LCSH, IA, OTR) goes through the subjects branch.
        source == .librivox
            ? CatalogGenreAxis.shelves(forLibriVoxGenres: genres(of: item))
            : CatalogGenreAxis.shelves(forSubjects: genres(of: item))
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

    /// E-Rest (7d192e2): a feed source is a TILE GRID too — the list form
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

    private var catalogGrid: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            // f374116 (H erweitert): genres are the STANDARD FORM where the
            // axis carries — tile row per filled shelf, counting chevron onto
            // the shelf grid. The chips died here (structure beats filter);
            // shelf = filter over the loaded stock, no second client.
            if hasChips {
                ForEach(shelves, id: \.key) { shelf in
                    genreRow(shelf)
                }
            }
            // LibriVox keeps its "new additions" as a second lens on the
            // same source — the overview shows one row per source only.
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

    /// H: one shelf's preview row (filter over `items`).
    ///
    /// R2 (09.08.): on THIS page a title belongs to exactly one shelf — its
    /// FIRST in browse order. „Eudemian Ethics" carries Philosophy AND
    /// Religion and therefore stood twice on one screen, which reads as a
    /// bug rather than as the truth of its subjects. On the shelf FULL pages
    /// it may appear in both — there it is the truth.
    @ViewBuilder
    private func genreRow(_ shelf: (key: String, title: String)) -> some View {
        let filtered = items.filter {
            CatalogGenreAxis.primaryShelf(among: shelvesOf($0)) == shelf.key
        }
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading(title: "", verbatimTitle: shelf.title,
                           total: filtered.count,
                           shown: RowPreview.cut(filtered).count,
                           destination: FreeAudiobooksRoute.shelf(source, shelf.key))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(RowPreview.cut(filtered)) { item in
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
        // 174f855: NACHSCHLAGEN — tap = detail, long-press = Play shortcut.
        // Auftrag O: OTR bundles push their show page (episode list).
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: source == .oldTimeRadio ? "waveform.and.mic" : "book.closed",
            onTap: {
                if FreeCatalogProvider.shared.isOldTimeRadio(itemId: item.id) {
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
            // P1: the fallback is a session state — once fallen back, deeper
            // pages browse the unfiltered corpus too (the returned flag
            // rides back in; the old page-1-only guard ended the trove after
            // one page for German users).
            guard let result = try? await ArchiveOrgClient.audiobooksOutsideLibriVox(
                rows: pageSize, languageCodes: codes, page: page, unfiltered: languageFallback)
            else { reachedEnd = true; return }
            languageFallback = result.unfiltered
            new = result.docs.compactMap { provider.remember(popular: $0) }
            if result.docs.count < pageSize { reachedEnd = true }
        case .gutenberg:
            // gutendex pages at 32; P1: same session-state rule as archive —
            // the same corner flagged in review (a first-page fallback that
            // never continued).
            var books = (try? await GutenbergClient.audiobooks(
                languages: languageFallback ? [] : codes, page: page)) ?? []
            if books.isEmpty, page == 1, !codes.isEmpty, !languageFallback {
                books = (try? await GutenbergClient.audiobooks(languages: [], page: 1)) ?? []
                if !books.isEmpty { languageFallback = true }
            }
            new = books.compactMap { provider.remember(gutenberg: $0) }
            if books.isEmpty { reachedEnd = true }
        case .oldTimeRadio:
            guard let docs = try? await ArchiveOrgClient.popularOldTimeRadio(
                rows: pageSize, page: page)
            else { reachedEnd = true; return }
            new = docs.compactMap { provider.remember(popular: $0) }
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


/// H erweitert: ONE parameterised shelf grid for the genre-carrying catalog
/// sources — the full filtered stock, staged loading rides the source page's
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
        CatalogGenreAxis.librivoxShelves.first { $0.key == shelfKey }?.title ?? ""
    }

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    FreeCatalogBookTile(
                        item: item,
                        // P7/O: OTR bundles in shelf grids push their show
                        // page too — same tap class everywhere.
                        onTap: {
                            if FreeCatalogProvider.shared.isOldTimeRadio(itemId: item.id) {
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
                // Regel 3: a failed load is not "this shelf is empty".
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

    /// R1 (09.08.): the shelf ASKS for its shelf instead of filtering the
    /// preview pool. The pool held 12-20 titles, so every shelf of every
    /// source together could never show more than that — the measured stock
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
            var fresh: [LibraryItem] = []
            switch source {
            case .librivox:
                // A shelf folds 2-3 LibriVox genres; ask for each and merge
                // (the API takes ONE genre per request).
                let genres = CatalogGenreAxis.librivoxGenres(forShelf: shelfKey)
                let offset = (page - 1) * pageSize
                for genre in genres {
                    let books = try await LibriVoxClient.books(genre: genre, limit: pageSize, offset: offset)
                    fresh += books.compactMap { provider.remember(book: $0) }
                }
            case .gutenberg:
                let topics = CatalogGenreAxis.subjects(forShelf: shelfKey)
                for topic in topics.prefix(2) {
                    let books = try await GutenbergClient.audiobooks(
                        languages: SuggestionLanguages.current(), page: page, topic: topic)
                    fresh += books.compactMap { provider.remember(gutenberg: $0) }
                }
            case .archiveBooks, .oldTimeRadio:
                let subjects = CatalogGenreAxis.subjects(forShelf: shelfKey)
                // BEFUND f220ecd: the shelf appends to the source's ONE base
                // query — rebuilding it lost the LibriVox de-duplication, the
                // licence clause and (via isCuratedArchiveDoc) the denylist.
                guard !subjects.isEmpty,
                      let base = ArchiveOrgClient.archiveBaseQuery(for: source)
                else { reachedEnd = true; return }
                let clause = subjects.prefix(6).map { "subject:\"\($0)\"" }.joined(separator: " OR ")
                let docs = try await ArchiveOrgClient.popular(
                    query: "\(base) AND (\(clause))", rows: pageSize, page: page)
                // Same gate as the row: de-duplication + denylist (893a7ea —
                // filtered wherever WE assemble the offer).
                fresh = docs.filter { FreeCatalog.isCuratedArchiveDoc($0) }
                    .compactMap { provider.remember(popular: $0) }
            default:
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


/// Auftrag O: the show page of an archive.org SERIES bundle (Old-Time-Radio
/// class) — the question "is that really 255 hours without a pause?"
/// answered honestly: the bundle's files ARE episodes, the app knew them all
/// along (FreeCatalog.archiveTracks); this page finally shows them. Blueprint
/// list form like the podcast episode lists; hundreds of episodes page in
/// staged windows like the Fundgruben.
struct ArchiveSeriesPage: View {
    /// One page carries both cases — a radio-play collection is a work in
    /// episodes, a netlabel release an album of tracks. What differs is the
    /// wording ("episodes" against "tracks", first broadcast against plain
    /// running time) and whether a row is an item of its own. Parameterised
    /// instead of a second page.
    enum Flavor { case series, album }

    let itemId: String
    /// The form to show while the item's own is still unknown. It comes from
    /// the route that opened the page and is nothing but a fallback: once the
    /// detail is loaded, the ITEM decides — see `effectiveFlavor`.
    var flavor: Flavor = .series
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var detail: LibraryItemDetail?
    @State private var failed = false
    @State private var visibleCount = 100

    private var tracks: [ABSAudioTrack] { detail?.media.tracks ?? [] }

    /// What the item IS, read from its collections.
    ///
    /// The route used to decide this: reached from the music tab an item was
    /// an album, from the books tab a work. The mixed surfaces can reach
    /// either, so the same reading became an album with a position per track
    /// once it was opened through the album route — and the work's position,
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
                if let detail {
                    header(detail)
                    episodeList
                } else if failed {
                    Text("Could not load the episode list. Tap to try again.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .onTapGesture { failed = false; Task { await load() } }
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
        .task { await load() }
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
                    // O3: the honest second line — the episode count the tile
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
                // O-P2: the leading heading repeats the title and leaves a
                // hole underneath — both go (measured, see tidiedDescription).
                Text(verbatim: FreeCatalog.tidiedDescription(
                    podcastPlainText(description),
                    title: detail.media.metadata?.title ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(6)
                    .padding(.horizontal)
            }
        }
    }

    /// O-P1: "07.12.1948 · 29 Min." — date in the user's format, duration in
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

    /// The title the ROW shows — the same derivation, so what lands in a
    /// playlist is what the person tapped (P4).
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
                // O-P1: the name's housekeeping head (series shorthand,
                // date, running number) is taken OFF the title — but the
                // date is the first broadcast and therefore moves into the
                // meta line instead of being thrown away.
                // The source's own track title wins; the file name stays the
                // fallback for items that state none. The OTR head patterns
                // (shorthand, date, running number) only exist in series —
                // music track names are left untouched.
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
                // f208790: "playlists are SONGS" — a catalog track is as
                // enqueueable as a server song, and it hands its title over
                // (P4 rule) so a cold cache cannot turn it into a placeholder.
                AddToPlaylistButton(itemId: songId,
                                    knownTitles: [songId: trackTitle(track)])
            }
        }
    }
}
