// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// Y23: THE global search as a FULL PAGE (no overlay, no drag handle — Y21) —
/// shown instead of the tab content while search mode is active. Content ends
/// above the bottom bar via the shared clearance (Y22); the search FIELD lives
/// in the bottom bar (Y17/Y19/Y24). On top the STANDING scope bar (Y20,
/// single select, gliding pill — the MediaTabBar pattern). An empty field
/// shows the browse deck (Y28) with the recent searches on top (Y30); typing
/// yields to the results with capped sections (Y18), the clearly set-apart
/// catalog card (Y16) and typed catalog rows (Y25).
struct SearchScreen: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Owned by LibraryView (the bar types, the page renders).
    @ObservedObject var model: GlobalSearchModel
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Y20: owned by LibraryView — `SearchScope.initial(for:)` on open.
    @Binding var scope: SearchScope
    /// A result was chosen: the caller closes the search and navigates.
    let onOpen: (SearchResult) -> Void
    /// b987483: category tiles navigate into the music LIBRARY pages
    /// (albums/songs/playlists/genres) — the caller closes the search and
    /// pushes the route on the music tab.
    var onOpenMusicRoute: (MusicRoute) -> Void = { _ in }

    /// Y28: in-page drill levels of the browse deck.
    private enum DeckDrill {
        case groups(title: String, groups: [(name: String, entries: [LibraryEntry])])
        case entries(title: String, entries: [LibraryEntry])
        case artists(title: String, artists: [MusicArtist])
        /// M5: catalog shows of ONE podcast genre (iTunes genre chart).
        case catalogShows(title: String, results: [SearchResult], footer: String? = nil)
    }

    @Environment(\.pushPodcastRoute) private var pushPodcastRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @State private var drill: [DeckDrill] = []
    /// Y15: explicit catalog view (via the trailing catalog-search row).
    @State private var showCatalog = false
    /// Y18: sections the user expanded past the cap.
    @State private var expandedSections: Set<SearchResult.Kind> = []
    @State private var recents = RecentSearches.list()
    @State private var artistCount: Int?
    /// Such-Freeze (a) 01.08: everything the deck derives from the full stock
    /// (grouping + ICU sorts over every book/episode/album) is computed ONCE
    /// per content change, OFF the main thread — never per body eval. The
    /// empty initial value lets the first open render instantly; the sections
    /// fill in as the build lands.
    @State private var deck = DeckData()
    @State private var pageWidth: CGFloat = 0
    @Namespace private var scopePillNS
    // Y60: the browse-deck book rows need the offline glyph like every other
    // MediaRowContent surface (the search-result rows already use isPlayableNow).
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    /// Y18: a section shows at most this many hits until expanded.
    static let sectionCap = 4

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isQueryActive: Bool {
        trimmedQuery.count >= GlobalSearchModel.minServerChars
    }

    /// Ranking context: the scope maps onto the tab whose sections lead.
    private var rankingTab: MediaType {
        switch scope {
        case .audiobooks: return .audiobooks
        case .podcasts: return .podcasts
        case .music: return .music
        case .radio: return .radio
        case .library: return .home
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            scopeBar
                .padding(.horizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isQueryActive {
                            resultsContent
                        } else {
                            deckContent
                        }
                    }
                    .padding(.bottom, 12)
                    .bottomBarClearance()
                    // Y29: a touch softer than the first pass (0.25 easeOut) —
                    // sections land with a gentle fade, no jump.
                    .animation(.smooth(duration: 0.35), value: model.sections)
                }
                .scrollDismissesKeyboard(.immediately)
                // A–Z jump rail (Y28, audiobooks deck root only) — floats over
                // the trailing edge, must NOT scroll with the content.
                .overlay(alignment: .trailing) {
                    if !isQueryActive, drill.isEmpty, scope == .audiobooks {
                        letterRail(proxy: proxy)
                    }
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in pageWidth = w }
            }
        }
        .task(id: model.query) {
            model.queryChanged(activeTab: rankingTab)
            // A new query resets the per-query view state.
            showCatalog = false
            expandedSections = []
            recents = RecentSearches.list()
        }
        .task(id: scope) {
            drill = []
            showCatalog = false
            if scope == .music || scope == .library {
                artistCount = (try? await AppSession.shared.musicProvider.allArtists())?.count
            }
        }
        .task(id: deckToken) {
            let entries = libraryViewModel.entries
            let shows = PodcastAutoContinue.allShows()
            let albums = AppSession.shared.musicProvider.cachedAlbumItems
            // The build runs DETACHED on purpose: it must never appear as a
            // main-thread stall (that was the Such-Freeze of 01.08.). The
            // measurement that proved it is gone — its question is answered.
            deck = await Task.detached(priority: .userInitiated) {
                DeckData.build(entries: entries, shows: shows, albums: albums)
            }.value
        }
    }

    /// Content identity of the deck's inputs (never counts — convention).
    private var deckToken: UInt64 {
        ContentToken.of(libraryViewModel.entries.map(\.id))
            ^ ContentToken.of(PodcastAutoContinue.allShows().map(\.feedURL))
            ^ ContentToken.of(AppSession.shared.musicProvider.cachedAlbumItems.map(\.id))
    }

    // MARK: - Y20 standing scope bar (single select, gliding pill)

    /// The MediaTabBar/N1d gap: a capsule pill inset uniformly by this value
    /// IS the concentric shape inside the bar capsule.
    private static let scopePillGap: CGFloat = 6

    /// F4: the radio scope appears only while the source is active — the
    /// Y37 isAvailable pattern, re-evaluated per render.
    private var visibleScopes: [SearchScope] {
        SearchScope.allCases.filter { $0 != .radio || RadioProvider.shared.isAvailable }
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(visibleScopes) { candidate in
                Button {
                    scope = candidate
                } label: {
                    Text(Self.scopeLabel(candidate))
                        .font(.subheadline.weight(scope == candidate ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(scope == candidate ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if scope == candidate {
                                Capsule()
                                    .fill(AppTheme.accent.opacity(0.16))
                                    .matchedGeometryEffect(id: "scopePill", in: scopePillNS)
                                    .padding(.vertical, Self.scopePillGap)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("scope-\(candidate.rawValue)")
            }
        }
        .animation(.snappy(duration: 0.3), value: scope)
        .padding(.horizontal, Self.scopePillGap)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
    }

    static func scopeLabel(_ scope: SearchScope) -> String {
        switch scope {
        case .library: return String(localized: "Library")
        case .audiobooks: return String(localized: "Audiobooks")
        case .podcasts: return String(localized: "Podcasts")
        case .music: return String(localized: "Music")
        case .radio: return String(localized: "Radio")
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsContent: some View {
        let own = model.sections.filter { $0.kind != .catalogShow && scope.kinds.contains($0.kind) }
        let catalog = model.sections.first { $0.kind == .catalogShow }
        let autoCatalog = own.isEmpty && !model.isSearching && !model.allSourcesFailed

        if model.allSourcesFailed {
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text("No source answered. Check your connection.")
            )
            .padding(.top, 24)
        } else if showCatalog || autoCatalog {
            // Explicit catalog view (row tap) or automatic on zero own hits —
            // clearly labeled either way.
            if autoCatalog && !showCatalog {
                Text("No matches in your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            catalogCard(catalog)
            if model.isSearching { searchingFooter }
        } else {
            ForEach(own) { section in
                sectionView(section)
            }
            if scope.includesCatalog {
                catalogCard(catalog)
            } else {
                catalogSearchRow
            }
            if model.isSearching { searchingFooter }
        }
    }

    private var searchingFooter: some View {
        HStack {
            ProgressView()
            Text("Searching…").foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    /// Always the last row of the library results — jumps to the catalog.
    private var catalogSearchRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showCatalog = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(AppTheme.accent)
                Text("Search the catalog for “\(trimmedQuery)”")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-catalog-row")
    }

    /// Y16: the catalog clearly set apart — its own grouped card, an explicit
    /// header + caption, and EVERY row carries the subscribe plus.
    @ViewBuilder
    private func catalogCard(_ section: GlobalSearchModel.Section?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // A2: the card names what it SHOWS. In the book scope these are
            // catalog readings, not shows — the kind title already carries
            // the right wording.
            (scope == .audiobooks
             ? Text("From the Free Catalogs")
             : Text("New Shows — from the catalog"))
                .font(.headline)
            Text("Not in your library yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let section, !section.results.isEmpty {
                ForEach(cappedResults(section)) { result in
                    resultRow(result)
                        .padding(.horizontal, -20)   // rows bring their own padding
                }
                expandButton(section)
            } else if !model.isSearching {
                Text("No results.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Sections (Y18 cap)

    private func cappedResults(_ section: GlobalSearchModel.Section) -> [SearchResult] {
        expandedSections.contains(section.kind)
            ? section.results
            : Array(section.results.prefix(Self.sectionCap))
    }

    @ViewBuilder
    private func expandButton(_ section: GlobalSearchModel.Section) -> some View {
        if section.results.count > Self.sectionCap, !expandedSections.contains(section.kind) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    _ = expandedSections.insert(section.kind)
                }
            } label: {
                Text("Show All (\(section.results.count))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GlobalSearchModel.Section) -> some View {
        Text(Self.sectionTitle(section.kind))
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        ForEach(cappedResults(section)) { result in
            resultRow(result)
                .transition(.opacity)
        }
        expandButton(section)
    }

    // MARK: - Rows

    /// c125ccd: the row's cover override — radio hits keep the gated
    /// station artwork; a CATALOG show WITHOUT its own image resolves the
    /// feed's channel artwork lazily (curated entries never pass the
    /// directory search that hands out artwork URLs). Everything else keeps
    /// the plain `coverURL` path.
    private func catalogCover(_ result: SearchResult) -> SearchRowCover? {
        SearchRowCover(result: result, placeholderSystemImage: Self.placeholder(result.kind))
    }

    /// Q1: sender + quiet reading marker ("LibriVox · Lesung 2").
    private func catalogBookMeta(_ result: SearchResult) -> String? {
        var parts: [String] = []
        if let source = result.sourceLabel { parts.append(source) }
        if let version = FreeCatalogProvider.shared.readingVersion(forItemId: result.id) {
            parts.append(String(localized: "Reading \(version)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result.kind {
            case .author:
                pushEntries(title: result.title) { $0.item.author == result.title }
            case .series:
                pushEntries(title: result.title) {
                    LibraryViewModel.baseSeriesName($0.item.media?.metadata?.seriesName) == result.title
                }
            default:
                onOpen(result)
            }
        } label: {
            HStack(spacing: 8) {
                MediaRowContent(
                    coverURL: result.coverURL,
                    eyebrow: result.subtitle,
                    title: result.title,
                    titleDimmed: !result.isPlayableNow,
                    coverDimmed: !result.isPlayableNow,
                    offlineBadge: !result.isPlayableNow,
                    // Y25: catalog hits say WHAT they are. Q1: book hits name
                    // their SENDER (LibriVox/Gutenberg/Archive), the licence
                    // capsule logic stays with the detail sheet.
                    meta: result.kind == .catalogShow ? String(localized: "Podcast")
                        : result.kind == .catalogBook ? catalogBookMeta(result) : nil,
                    placeholderSystemImage: Self.placeholder(result.kind),
                    // Paket B: mirrored shows carry the origin capsule in
                    // search too (show hits carry the feed URL as id).
                    showsOriginCapsule: result.kind == .show
                        && PodcastSubscriptions.shared.isMirrored(feedURL: result.id),
                    // cd5cc4a (1): radio hits share the ONE gated artwork
                    // (gradient+initials fallback) instead of the gray box.
                    coverOverride: catalogCover(result)
                )
                if result.kind == .author || result.kind == .series {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // Catalog rows carry the subscribe plus — function AND marker;
                // own results carry nothing there.
                if result.kind == .catalogShow {
                    PodcastSubscribeBadge(feedURL: result.id)
                }
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bookEntryRow(_ entry: LibraryEntry) -> some View {
        let unavailable = MediaAvailability.offlineUnavailable(
            isConnected: networkMonitor.isConnected,
            isDownloaded: downloadManager.isDownloaded(itemId: entry.id))
        return Button {
            onOpen(SearchResult(id: entry.id, kind: .book, title: entry.item.title))
        } label: {
            MediaRowContent(
                coverURL: AppSession.shared.coverURL(forItemId: entry.id),
                eyebrow: entry.item.author,
                title: entry.item.title,
                titleDimmed: unavailable,
                coverDimmed: unavailable,
                offlineBadge: unavailable,
                placeholderSystemImage: "book.closed"
            )
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Author/series hits drill IN-PAGE (results and deck share the stack).
    private func pushEntries(title: String, matches: (LibraryEntry) -> Bool) {
        withAnimation(.snappy(duration: 0.2)) {
            drill.append(.entries(title: title, entries: libraryViewModel.entries.filter(matches)))
        }
    }

    // MARK: - Y28 browse deck

    @ViewBuilder
    private var deckContent: some View {
        if let level = drill.last {
            drillBackChip
            switch level {
            case .groups(_, let groups):
                ForEach(groups, id: \.name) { group in
                    deckEntryRow(title: group.name, count: group.entries.count) {
                        withAnimation(.snappy(duration: 0.2)) {
                            drill.append(.entries(title: group.name, entries: group.entries))
                        }
                    }
                }
            case .entries(_, let entries):
                ForEach(entries) { entry in
                    bookEntryRow(entry)
                }
            case .catalogShows(_, let results, let footer):
                // The SAME result row the typed search uses for catalog shows
                // (subscribe/preview routing via onOpen — no second row idiom).
                if results.isEmpty {
                    Text("No results.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(results) { resultRow($0) }
                    // e4bd910/hoerspiele: honesty line (depublication).
                    if let footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
            case .artists(_, let artists):
                ForEach(artists) { artist in
                    deckEntryRow(title: artist.name ?? "—", count: artist.albumCount ?? 0) {
                        // Cache the artist so the shared resolver (artist route)
                        // finds it — same path as a server search hit.
                        let music = AppSession.shared.musicProvider
                        music.cacheSearchedArtist(artist)
                        onOpen(SearchResult(id: music.itemId(artistId: artist.id), kind: .artist,
                                            title: artist.name ?? "—"))
                    }
                }
            }
        } else {
            recentsRow
            deckTier
            deckRaster
        }
    }

    private var drillBackChip: some View {
        HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { _ = drill.popLast() }
            } label: {
                Label(drillTitle, systemImage: "chevron.left")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var drillTitle: String {
        switch drill.last {
        case .groups(let title, _), .entries(let title, _), .artists(let title, _),
             .catalogShows(let title, _, _):
            return title
        case nil:
            return ""
        }
    }

    /// Y30: the recent searches on top of the deck — tap re-runs, long-press
    /// deletes one, "Clear" empties the list.
    @ViewBuilder
    private var recentsRow: some View {
        if !recents.isEmpty {
            HStack {
                Text("Recent Searches").font(.headline)
                Spacer()
                Button {
                    RecentSearches.clear()
                    recents = []
                } label: {
                    Text("Clear")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents, id: \.self) { term in
                        Button {
                            model.query = term
                        } label: {
                            Text(term)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                RecentSearches.remove(term)
                                recents = RecentSearches.list()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 10)
        }
    }

    /// Upper tier (Y43): drilldown entry points as Apple-Podcasts-style TILES —
    /// a 2-column raster of glyph + title + count. Same targets as the former
    /// rows (drill or scope switch); a deliberate trial, cheap to revert (render
    /// `deckEntries` as `deckEntryRow`s instead of `deckEntryTile`s). Audiobooks
    /// get Authors/Series/Genres, music gets Artists; podcasts/radio have none
    /// (shows/stations ARE the unit). The library scope shows the mixed tier.
    @ViewBuilder
    private var deckTier: some View {
        let entries = deckEntries
        if !entries.isEmpty {
            LazyVGrid(columns: Self.tierColumns, spacing: 12) {
                ForEach(entries) { deckEntryTile($0) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private static let tierColumns = [GridItem(.flexible(), spacing: 12),
                                      GridItem(.flexible(), spacing: 12)]

    /// One entry-point descriptor — decouples the tier's data (title, glyph,
    /// count, target) from its presentation, so the tile/row swap is one line.
    private struct DeckEntry: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        /// nil hides the numeral (pages whose stock the deck doesn't hold).
        let count: Int?
        let action: () -> Void
    }

    private var deckEntries: [DeckEntry] {
        switch scope {
        case .audiobooks: return audiobookDeckEntries
        case .music: return musicDeckEntries
        case .podcasts, .radio: return []
        case .library:
            return audiobookDeckEntries + [
                DeckEntry(id: "shows", title: String(localized: "Shows"),
                          systemImage: "mic.fill", count: deck.shows.count) { scope = .podcasts },
                artistDeckEntry,
                DeckEntry(id: "albums", title: String(localized: "Albums"),
                          systemImage: "square.stack.fill", count: deck.albums.count) { scope = .music },
            ]
        }
    }

    /// b987483: the music deck offers ALL library entry points as category
    /// tiles — albums · songs · playlists · genres (the M3 discovery entry,
    /// like the podcast genre chips) — plus the artist drill. Counts render
    /// where the deck knows them; the pages themselves load fresh.
    private var musicDeckEntries: [DeckEntry] {
        [
            artistDeckEntry,
            DeckEntry(id: "music-albums", title: String(localized: "Albums"),
                      systemImage: "square.stack.fill", count: deck.albums.count) {
                onOpenMusicRoute(.albums)
            },
            DeckEntry(id: "music-songs", title: String(localized: "Songs"),
                      systemImage: "music.note", count: nil) {
                onOpenMusicRoute(.songs)
            },
            DeckEntry(id: "music-playlists", title: String(localized: "Playlists"),
                      systemImage: "music.note.list", count: nil) {
                // The route carries its list — fetched fresh via the ONE
                // provider access point (junk-cleaned like everywhere).
                Task { @MainActor in
                    let lists = PlaylistPresentation.realPlaylists(
                        (try? await AppSession.shared.musicProvider.allPlaylists()) ?? [])
                    onOpenMusicRoute(.playlists(lists))
                }
            },
            DeckEntry(id: "music-genres", title: String(localized: "Genres"),
                      systemImage: "guitars", count: nil) {
                onOpenMusicRoute(.genres)
            },
        ]
        // UMZUG (e4bd910/klassik-in-die-suche): the catalog entry lives in
        // the DISCOVER context (search deck), the library list stays personal
        // — same CategoryTile, same route, same gates (pill toggle + master).
        + (freeClassicalDeckVisible
            // The title comes from the DATA, so the shelf cannot be called one
            // thing in the row and another in the deck.
            ? [DeckEntry(id: "music-free-classical", title: ArchiveMusicCatalog.classical.title,
                         systemImage: "music.quarternote.3", count: nil) {
                onOpenMusicRoute(.archiveMusic(ArchiveMusicCatalog.classical))
            }]
            : [])
    }

    private var freeClassicalDeckVisible: Bool {
        FreeCatalogActivation.effective(
            master: AppStorageKeys.freeCatalogsMasterActive,
            feature: AppStorageKeys.freeClassicalActive,
            service: AppStorageKeys.archiveBooksActive)
    }

    private var audiobookDeckEntries: [DeckEntry] {
        [
            DeckEntry(id: "authors", title: String(localized: "Authors"),
                      systemImage: "person.2.fill", count: deck.authorGroups.count) {
                withAnimation(.snappy(duration: 0.2)) {
                    drill.append(.groups(title: String(localized: "Authors"), groups: deck.authorGroups))
                }
            },
            DeckEntry(id: "series", title: String(localized: "Series"),
                      systemImage: "books.vertical.fill", count: deck.seriesGroups.count) {
                withAnimation(.snappy(duration: 0.2)) {
                    drill.append(.groups(title: String(localized: "Series"), groups: deck.seriesGroups))
                }
            },
            DeckEntry(id: "genres", title: String(localized: "Genres"),
                      systemImage: "theatermasks.fill", count: deck.genreGroups.count) {
                withAnimation(.snappy(duration: 0.2)) {
                    drill.append(.groups(title: String(localized: "Genres"), groups: deck.genreGroups))
                }
            },
        ]
    }

    private var artistDeckEntry: DeckEntry {
        DeckEntry(id: "artists", title: String(localized: "Artists"),
                  systemImage: "music.mic", count: artistCount ?? 0) {
            Task {
                let artists = (try? await AppSession.shared.musicProvider.allArtists()) ?? []
                withAnimation(.snappy(duration: 0.2)) {
                    if scope != .music { scope = .music }
                    drill.append(.artists(title: String(localized: "Artists"), artists: artists))
                }
            }
        }
    }

    /// Apple-Podcasts-style entry tile: glyph + count on top, title below.
    // M3: the tile itself moved to the shared `CategoryTile` (the music
    /// genre grid reuses the exact same chip — Regel 2, one idiom).
    private func deckEntryTile(_ entry: DeckEntry) -> some View {
        CategoryTile(title: entry.title, systemImage: entry.systemImage,
                     count: entry.count, accessibilityId: "deck-tier-\(entry.id)",
                     action: entry.action)
    }

    /// Drilldown sub-level row (still a row — the drilled lists of individual
    /// authors/series/artists are long, not a tile grid). Y43 only changed the
    /// upper ENTRY tier to tiles.
    private func deckEntryRow(title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Y28 lower tier: cover raster (existing components, Regel 2)

    @ViewBuilder
    private var deckRaster: some View {
        switch scope {
        case .audiobooks:
            audiobookRaster
        case .podcasts:
            podcastGenreChips
            showRaster
        case .music:
            albumRaster
        case .radio:
            EmptyView()   // radio browses on its own tab; search is the catalog
        case .library:
            EmptyView()   // the mixed tier IS the library deck
        }
    }

    /// M5: podcast genre chips — the SAME CategoryTile grid as the deck tier
    /// and the music genres (one chip idiom). Tap loads the KEYLESS iTunes
    /// genre chart and drills into catalog-show rows; a failed/empty load
    /// shows "No results" in the drill (visible, rule 3).
    @State private var loadingGenreId: Int?
    private var podcastGenreChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Genre").font(.headline).padding(.horizontal, 16)
            LazyVGrid(columns: Self.tierColumns, spacing: 12) {
                // e4bd910/hoerspiele: the curated public-broadcast entry —
                // same chip idiom, drills into the DATA list (verified
                // feeds), preview/subscribe like any catalog row.
                // 8d49a8e: the tile leads to the OWN page (charts by genre +
                // curated socket) instead of the flat curation list — the
                // charts carry the bulk, the socket only what they miss.
                // Paket 4: the tile is the THIRD entrance to the merged
                // page (11be262: same surface, one title everywhere).
                CategoryTile(title: String(localized: "Audiobooks and Radio Plays"),
                             systemImage: "waveform.and.mic",
                             accessibilityId: "podcast-genre-hoerspiele") {
                    pushFreeAudiobooksRoute(.area)
                }
                ForEach(PodcastGenres.curated) { genre in
                    CategoryTile(title: genre.title, systemImage: genre.systemImage,
                                 accessibilityId: "podcast-genre-\(genre.itunesGenreId)") {
                        openPodcastGenre(genre)
                    }
                    .overlay(alignment: .topTrailing) {
                        if loadingGenreId == genre.itunesGenreId {
                            ProgressView().padding(10)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private func openPodcastGenre(_ genre: PodcastGenre) {
        guard loadingGenreId == nil else { return }
        loadingGenreId = genre.itunesGenreId
        Task {
            let hits = (try? await ITunesDirectory().topPodcasts(genreId: genre.itunesGenreId, limit: 30)) ?? []
            let results = hits.map { hit in
                SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                             subtitle: hit.author,
                             coverURL: hit.artworkURL.flatMap(URL.init(string:)))
            }
            loadingGenreId = nil
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.catalogShows(title: genre.title, results: results))
            }
        }
    }

    /// The LibraryView grid math (min column 108, spacing 16, padding 16) —
    /// one measured width drives column count AND cell size.
    private static let minColumnWidth: CGFloat = 108
    private static let gridSpacing: CGFloat = 16
    private static let gridPadding: CGFloat = 16

    private var columnCount: Int {
        guard pageWidth > 0 else { return 3 }
        let available = pageWidth - Self.gridPadding * 2
        return max(Int((available + Self.gridSpacing) / (Self.minColumnWidth + Self.gridSpacing)), 1)
    }

    private var cellWidth: CGFloat {
        guard pageWidth > 0 else { return 132 }
        let available = pageWidth - Self.gridPadding * 2
        let totalSpacing = Self.gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
    }

    private var rasterColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.gridSpacing), count: columnCount)
    }

    /// Audiobooks: alphabetical sections with letter anchors for the A–Z rail.
    private var audiobookRaster: some View {
        ForEach(deck.letterSections, id: \.letter) { section in
            Text(section.letter)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .id("letter-\(section.letter)")
            CoverGrid(columns: rasterColumns) {
                ForEach(section.entries) { entry in
                    BookGridCell(entry: entry, width: cellWidth,
                                 playerCoordinator: playerCoordinator,
                                 libraryViewModel: libraryViewModel)
                }
            }
            .padding(.horizontal, Self.gridPadding)
            .padding(.bottom, 12)
        }
    }

    private var showRaster: some View {
        CoverGrid(columns: rasterColumns) {
            ForEach(deck.shows, id: \.feedURL) { show in
                MediaTile(
                    title: show.title,
                    coverURL: show.artworkURL.flatMap { URL(string: $0) },
                    onTap: {
                        onOpen(SearchResult(id: show.feedURL, kind: .show, title: show.title))
                    }
                )
            }
        }
        .padding(.horizontal, Self.gridPadding)
    }

    private var albumRaster: some View {
        CoverGrid(columns: rasterColumns) {
            ForEach(deck.albums) { item in
                AlbumCell(item: item, width: cellWidth, playerCoordinator: playerCoordinator)
            }
        }
        .padding(.horizontal, Self.gridPadding)
    }

    /// A–Z rail: tap a letter → jump to its section.
    private func letterRail(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(deck.letterSections, id: \.letter) { section in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 20, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 1)
    }

    // MARK: - Data

    struct LetterSection {
        let letter: String
        let entries: [LibraryEntry]
    }

    /// Such-Freeze (a): the deck's derived data, built off-main in one pass.
    struct DeckData {
        var authorGroups: [(name: String, entries: [LibraryEntry])] = []
        var genreGroups: [(name: String, entries: [LibraryEntry])] = []
        var seriesGroups: [(name: String, entries: [LibraryEntry])] = []
        var letterSections: [LetterSection] = []
        var shows: [PodcastShow] = []
        var albums: [LibraryItem] = []

        nonisolated static func build(entries: [LibraryEntry], shows: [PodcastShow],
                                      albums: [LibraryItem]) -> DeckData {
            var deck = DeckData()
            deck.authorGroups = LibraryViewModel.authorGroups(of: entries)
            deck.genreGroups = LibraryViewModel.genreGroups(of: entries)
            // Series grouped like the author groups — key-folded dedupe, sorted.
            var indexByKey: [String: Int] = [:]
            var groups: [(name: String, entries: [LibraryEntry])] = []
            for entry in entries {
                guard let name = LibraryViewModel.baseSeriesName(entry.item.media?.metadata?.seriesName) else { continue }
                let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if let idx = indexByKey[key] {
                    groups[idx].entries.append(entry)
                } else {
                    indexByKey[key] = groups.count
                    groups.append((name: name, entries: [entry]))
                }
            }
            deck.seriesGroups = groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // Alphabetical, diacritic-folded; no letter start lands in "#".
            let sorted = entries.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }
            var sections: [LetterSection] = []
            for entry in sorted {
                let first = entry.item.title.first.map {
                    String($0).folding(options: .diacriticInsensitive, locale: nil).uppercased()
                } ?? "#"
                let letter = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
                if let last = sections.indices.last, sections[last].letter == letter {
                    sections[last] = LetterSection(letter: letter, entries: sections[last].entries + [entry])
                } else {
                    sections.append(LetterSection(letter: letter, entries: [entry]))
                }
            }
            deck.letterSections = sections
            deck.shows = shows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            deck.albums = albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return deck
        }
    }

    // MARK: - Labels

    static func sectionTitle(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .book: return String(localized: "Books")
        case .author: return String(localized: "Authors")
        case .series: return String(localized: "Series")
        case .show: return String(localized: "Shows")
        case .episode: return String(localized: "Episodes")
        case .album: return String(localized: "Albums")
        case .artist: return String(localized: "Artists")
        case .song: return String(localized: "Songs")
        case .playlist: return String(localized: "Playlists")
        case .catalogShow: return String(localized: "New Shows")
        // Q1 (D2): the card names the CONTENT and its family of senders.
        case .catalogBook: return String(localized: "From the Free Catalogs")
        case .radioStation: return String(localized: "Radio Stations")
        }
    }

    static func placeholder(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .book, .series, .catalogBook: return "book.closed"
        case .author: return "person"
        case .show, .episode, .catalogShow: return "mic"
        case .album, .song: return "music.note"
        case .playlist: return "music.note.list"
        case .artist: return "music.mic"
        case .radioStation: return "dot.radiowaves.left.and.right"
        }
    }
}
