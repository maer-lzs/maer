// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// THE global search as a FULL PAGE (no overlay, no drag handle).
/// Shown instead of the tab content while search mode is active. Content ends
/// above the bottom bar via the shared clearance; the search FIELD lives in
/// the bottom bar. On top the STANDING scope bar (single select, gliding
/// pill, the MediaTabBar pattern). An empty field shows the browse deck with
/// the recent searches on top; typing yields to the results with capped
/// sections, the clearly set-apart catalog card and typed catalog rows.
struct SearchScreen: View {
    @Environment(\.catalogFacts) private var catalogFacts
    @Environment(\.itemRouter) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var libraryViewModel: LibraryViewModel
    /// Owned by LibraryView (the bar types, the page renders).
    @ObservedObject var model: GlobalSearchModel
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Owned by LibraryView. `SearchScope.initial(for:)` on open.
    @Binding var scope: SearchScope
    /// A result was chosen: the caller closes the search and navigates.
    let onOpen: (SearchResult) -> Void
    /// Category tiles navigate into the music LIBRARY pages
    /// (albums/songs/playlists/genres). The caller closes the search and
    /// pushes the route on the music tab.
    var onOpenMusicRoute: (MusicRoute) -> Void = { _ in }

    @Environment(\.pushPodcastRoute) private var pushPodcastRoute
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @Environment(\.pushLibraryListRoute) private var pushLibraryListRoute
    @State private var drill: [SearchDeckDrill] = []
    /// Explicit catalog view (via the trailing catalog-search row).
    @State private var showCatalog = false
    /// Sections the user expanded past the cap.
    @State private var expandedSections: Set<SearchResult.Kind> = []
    @State private var recents = RecentSearches.list()
    /// Everything the deck shows, built behind the door and per content
    /// change. The empty initial value lets the first open render instantly;
    /// the sections fill in as the build lands.
    @State private var deck = SearchDeck()
    @State private var pageWidth: CGFloat = 0
    /// The music server the hits are narrowed to; nil shows all.
    @State private var musicServer: MusicSourceRule.Server?
    @Namespace private var scopePillNS
    // The browse-deck book rows need the offline glyph like every other
    // MediaRowContent surface (the search-result rows already use isPlayableNow).
    @Environment(\.isOnline) private var isOnline

    /// A section shows at most this many hits until expanded.
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
            serverRow
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isQueryActive {
                            resultsContent
                        } else {
                            deckContent
                        }
                    }
                    // The catalog view is a list of its own. Measured on
                    // iOS 27: switching the same lazy stack from the long
                    // library results to the short catalog card, under the
                    // row's animation, left it drawing nothing at all, a
                    // white page (on iOS 26.5 the same code drew the card).
                    // The deck's drills and the scope switch swap the same
                    // stack and draw on iOS 27 without this (measured by
                    // the search journey), so they keep their scroll place.
                    .id(showCatalog)
                    .padding(.bottom, 12)
                    .bottomBarClearance()
                    // A touch softer than the first pass (0.25 easeOut).
                    // Sections land with a gentle fade, no jump.
                    .animation(.smooth(duration: 0.35), value: model.sections)
                }
                .scrollDismissesKeyboard(.immediately)
                // A–Z jump rail (audiobooks deck root only). Floats over
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
                deck.artistCount = await SearchDoor.artistCount()
            }
        }
        .task(id: SearchDoor.deckToken(entries: libraryViewModel.entries)) {
            var built = await SearchDoor.deck(entries: libraryViewModel.entries)
            // The artist count travels on its own way and may have landed
            // while the build ran. Read it here, not before the await.
            built.artistCount = deck.artistCount
            deck = built
        }
    }

    // MARK: - Standing scope bar (single select, gliding pill)

    /// The MediaTabBar gap: a capsule pill inset uniformly by this value
    /// IS the concentric shape inside the bar capsule.
    private static let scopePillGap: CGFloat = 6

    /// The radio scope appears only while the source is active. The
    /// isAvailable pattern, re-evaluated per render, asked at the door.
    private var visibleScopes: [SearchScope] { SearchDoor.visibleScopes() }

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

    // MARK: - Which music server

    /// The server the hits are narrowed to, while it is still one of two.
    /// A server that stopped serving music falls back to all.
    private var narrowedServer: MusicSourceRule.Server? {
        guard scope == .music, let musicServer,
              router.musicServers().contains(where: { $0.server == musicServer }) else { return nil }
        return musicServer
    }

    /// Under Music, with two music servers and a query: all hits, or those
    /// of one server. A row that scrolls, so no name is ever cut.
    @ViewBuilder
    private var serverRow: some View {
        let servers = router.musicServers()
        if scope == .music, isQueryActive, servers.count > 1 {
            MusicServerRow(servers: servers, chosen: narrowedServer) { musicServer = $0 }
        }
    }

    /// The sections with only the chosen server's hits, empty ones gone.
    private func narrowed(_ sections: [GlobalSearchModel.Section]) -> [GlobalSearchModel.Section] {
        guard let chosen = narrowedServer else { return sections }
        return sections.compactMap { section in
            var kept = section
            kept.results = section.results.filter { MusicSourceRule.keeps($0.id, chosen: chosen) }
            return kept.results.isEmpty ? nil : kept
        }
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
        let unnarrowed = model.sections.filter { $0.kind != .catalogShow && scope.kinds.contains($0.kind) }
        let own = narrowed(unnarrowed)
        let catalog = model.sections.first { $0.kind == .catalogShow }
        // The catalog steps in when the library has nothing, not when one
        // server has nothing: that is said in its own line below.
        let emptyLine = SearchEmptyLine.of(libraryEmpty: unnarrowed.isEmpty, shownEmpty: own.isEmpty,
                                           narrowed: narrowedServer != nil, searching: model.isSearching,
                                           allSourcesFailed: model.allSourcesFailed)
        let autoCatalog = emptyLine == .library

        if model.allSourcesFailed {
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text("No source answered. Check your connection.")
            )
            .padding(.top, 24)
        } else if showCatalog || autoCatalog {
            // Explicit catalog view (row tap) or automatic on zero own hits.
            // Clearly labeled either way.
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
            if emptyLine == .server, let chosen = narrowedServer,
               let name = router.musicServers().first(where: { $0.server == chosen })?.name {
                Text("No matches on \(name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// Always the last row of the library results. Jumps to the catalog.
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

    /// The catalog clearly set apart. Its own grouped card, an explicit
    /// header + caption, and EVERY row carries the subscribe plus.
    @ViewBuilder
    private func catalogCard(_ section: GlobalSearchModel.Section?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The card names what it SHOWS. In the book scope these are
            // catalog readings, not shows. The kind title already carries
            // the right wording.
            (scope == .audiobooks
             ? Text("From the Free Catalogs")
             : Text("New Shows, from the catalog"))
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

    // MARK: - Sections (capped)

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

    /// The row's cover override. Radio hits keep the gated
    /// station artwork; a CATALOG show WITHOUT its own image resolves the
    /// feed's channel artwork lazily (curated entries never pass the
    /// directory search that hands out artwork URLs). Everything else keeps
    /// the plain `coverURL` path.
    private func catalogCover(_ result: SearchResult) -> SearchRowCover? {
        SearchRowCover(result: result, placeholderSystemImage: Self.placeholder(result.kind))
    }

    /// Sender + quiet reading marker ("LibriVox · Lesung 2").
    private func catalogBookMeta(_ result: SearchResult) -> String? {
        var parts: [String] = []
        if let source = result.sourceLabel { parts.append(source) }
        if let version = catalogFacts.readingVersion(result.id) {
            parts.append(String(localized: "Reading \(version)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button {
            switch result.kind {
            // The page of the books tab, not a drill level of the search:
            // the drill was only rendered without a query, so a tap on a
            // hit did nothing visible.
            case .author:
                pushLibraryListRoute(.author(result.title))
            case .series:
                pushLibraryListRoute(.series(result.title))
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
                    // Catalog hits say WHAT they are: book hits name
                    // their SENDER (LibriVox/Gutenberg/Archive), the licence
                    // capsule logic stays with the detail sheet.
                    meta: result.kind == .catalogShow ? String(localized: "Podcast")
                        : result.kind == .catalogBook ? catalogBookMeta(result) : nil,
                    placeholderSystemImage: Self.placeholder(result.kind),
                    // Mirrored shows carry the origin capsule in
                    // search too (show hits carry the feed URL as id).
                    showsOriginCapsule: result.kind == .show
                        && SearchDoor.isMirrored(feedURL: result.id),
                    // A music hit's server, when there are two music servers.
                    // The row capsule, not `sourceLabel`: that one is a
                    // ranking reason, and "jellyfin" would find every hit.
                    sourceCapsule: router.sourceLabel(result.id),
                    // Radio hits share the ONE gated artwork
                    // (gradient+initials fallback) instead of the gray box.
                    coverOverride: catalogCover(result)
                )
                if result.kind == .author || result.kind == .series {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                // Catalog rows carry the subscribe plus. Function AND marker;
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

    // MARK: - Browse deck

    @ViewBuilder
    private var deckContent: some View {
        if let level = drill.last {
            drillBackChip
            switch level {
            case .catalogShows(_, let results, let footer):
                // The SAME result row the typed search uses for catalog shows
                // (subscribe/preview routing via onOpen. No second row idiom).
                if results.isEmpty {
                    drillSentence(String(localized: "No results."))
                } else {
                    ForEach(results) { resultRow($0) }
                    // Honesty line (depublication).
                    if let footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
            case .artists(_, let artists):
                if artists.isEmpty {
                    drillSentence(String(localized: "No results."))
                } else {
                    ForEach(artists) { artist in
                        deckEntryRow(title: artist.name ?? String(localized: "Unknown Artist"), count: artist.albumCount ?? 0,
                                     capsule: router.sourceLabel(artist.itemId)) {
                            onOpen(SearchDoor.hit(forArtist: artist))
                        }
                    }
                }
            case .failed(_, let sentence, let retry):
                drillSentence(sentence)
                // The same question once more, from the level below: the
                // failed page goes, and the answer lands as its own drill.
                Button("Try Again") {
                    _ = drill.popLast()
                    ask(again: retry)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("search-drill-retry")
            }
        } else {
            recentsRow
            deckTier
            deckRaster
        }
    }

    /// The one line a drill page says when it has no rows: that there are
    /// none, or that its source could not answer. Never an empty page.
    private func drillSentence(_ sentence: String) -> some View {
        Text(sentence)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .accessibilityIdentifier("search-drill-sentence")
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
            .accessibilityIdentifier("search-drill-back")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var drillTitle: String { drill.last?.title ?? "" }

    /// The recent searches on top of the deck. Tap re-runs, long-press
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

    /// Upper tier: the drilldown entry points as tiles, a 2-column raster of
    /// glyph, title and count. WHICH tiles a scope offers and where they lead
    /// is `SearchDeckTiles`; the view renders them and performs the named
    /// destination, because only it owns the navigation path and the scope
    /// binding. The SHARED deck grid; the music tab's library list is the same
    /// component with its own entries.
    private var deckTier: some View {
        SearchDeckTier(counts: deck.counts) { counts in
            SearchDeckTiles
                .tiles(scope: scope, counts: counts)
                .map { tile in
                    CategoryDeckEntry(id: tile.id, title: tile.title,
                                      systemImage: tile.systemImage, count: tile.count) {
                        go(to: tile.destination)
                    }
                }
        }
    }

    /// Performing a named destination. Every case ends in a drill, a scope
    /// switch or a route, so a new tile cannot lead nowhere.
    private func go(to destination: SearchDeckDestination) {
        switch destination {
        case .group(let kind):
            // The page of the books tab, not a drill level of the search.
            pushLibraryListRoute(.groups(kind))
        case .artists:
            Task {
                let artists = await SearchDoor.artists()
                withAnimation(.snappy(duration: 0.2)) {
                    // The artist drill lives on the music scope, so a tap in
                    // the mixed library deck moves there first.
                    if scope != .music { scope = .music }
                    let title = String(localized: "Artists")
                    if let artists {
                        drill.append(.artists(title: title, artists: artists))
                    } else {
                        drill.append(.failed(title: title,
                                             sentence: String(localized: "Artists could not be loaded."),
                                             retry: .artists))
                    }
                }
            }
        case .scope(let target):
            scope = target
        case .albums:
            onOpenMusicRoute(.albums)
        case .songs:
            onOpenMusicRoute(.songs)
        case .playlists:
            // The route carries its list. Fetched fresh via the ONE
            // provider access point (junk-cleaned like everywhere).
            // A failed fetch stays on the deck and says so; the page would
            // claim there are no playlists.
            Task { @MainActor in
                if let lists = await SearchDoor.playlists() {
                    onOpenMusicRoute(.playlists(lists))
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
                        drill.append(.failed(title: String(localized: "Playlists"),
                                             sentence: String(localized: "Playlists could not be loaded."),
                                             retry: .playlists))
                    }
                }
            }
        case .genres:
            onOpenMusicRoute(.genres)
        case .downloaded:
            onOpenMusicRoute(.downloaded)
        case .shelf(let area):
            onOpenMusicRoute(.archiveMusic(area))
        }
    }

    /// Drilldown sub-level row (still a row. The drilled list of artists is
    /// long, not a tile grid). Only the upper ENTRY tier is tiles.
    private func deckEntryRow(title: String, count: Int, capsule: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckEntryRowLabel(title: title, count: count, capsule: capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lower tier: cover raster (existing components)

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

    /// Podcast genre chips. The SAME CategoryTile grid as the deck tier
    /// and the music genres (one chip idiom). Tap loads the KEYLESS iTunes
    /// genre chart and drills into catalog-show rows; a failed/empty load
    /// shows "No results" in the drill (visible, rule 3).
    @State private var loadingGenreId: Int?
    private var podcastGenreChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Genre").font(.headline).padding(.horizontal, 16)
            LazyVGrid(columns: CategoryDeckGrid.columns(for: typeSize), spacing: 12) {
                // The curated public-broadcast entry. Same chip idiom,
                // drills into the DATA list (verified
                // feeds), preview/subscribe like any catalog row.
                // The tile leads to the OWN page (charts by genre +
                // curated socket) instead of the flat curation list. The
                // charts carry the bulk, the socket only what they miss.
                // The tile is the THIRD entrance to the merged page. The tile
                // carries the short title (the full one was cut on a 375 pt
                // screen); page and row heading keep the full title, there
                // is room to say that radio plays are in it.
                CategoryTile(title: String(localized: "Audiobooks"),
                             systemImage: "waveform.and.mic",
                             accessibilityId: "podcast-genre-hoerspiele") {
                    pushFreeAudiobooksRoute(.area)
                }
                // VoiceOver says what is behind the short title.
                .accessibilityLabel(Text("Audiobooks and Radio Plays"))
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

    /// A failed drill's question once more, by the same way it was asked.
    private func ask(again retry: SearchDeckRetry) {
        switch retry {
        case .artists: go(to: .artists)
        case .playlists: go(to: .playlists)
        case .podcastGenre(let genre): openPodcastGenre(genre)
        }
    }

    private func openPodcastGenre(_ genre: PodcastGenre) {
        guard loadingGenreId == nil else { return }
        loadingGenreId = genre.itunesGenreId
        Task {
            let hits = await SearchDoor.topShows(genreId: genre.itunesGenreId)
            loadingGenreId = nil
            guard let hits else {
                // The directory did not answer: that is not "no shows".
                withAnimation(.snappy(duration: 0.2)) {
                    drill.append(.failed(title: genre.title,
                                         sentence: String(localized: "Shows could not be loaded."),
                                         retry: .podcastGenre(genre)))
                }
                return
            }
            let results = hits.map { hit in
                SearchResult(id: hit.feedURL, kind: .catalogShow, title: hit.title,
                             subtitle: hit.author,
                             coverURL: hit.artworkURL.flatMap(URL.init(string:)))
            }
            withAnimation(.snappy(duration: 0.2)) {
                drill.append(.catalogShows(title: genre.title, results: results))
            }
        }
    }

    /// The LibraryView grid math (min column 108, spacing 16, padding 16).
    /// One measured width drives column count AND cell size.
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
                    lock: deck.locks[show.feedURL] ?? .none,
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
        // The card names the CONTENT and its family of senders.
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

/// The upper tier of the search deck. The deck's counts come from the
/// library, except the one the library cannot know: what lies on the device,
/// counted by the SAME rule the music tab uses, so both tiles show one number.
/// That number is why this tier observes the download manager.
private struct SearchDeckTier: View {
    private let downloadManager = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    let counts: SearchDeckCounts
    let entries: (SearchDeckCounts) -> [CategoryDeckEntry]

    var body: some View {
        var withDownloads = counts
        withDownloads.downloaded = MediaFamily.musicCount(in: downloadManager.downloadedItemIds)
        return CategoryDeckGrid(entries: entries(withDownloads))
    }
}

/// Under Music with two music servers: all hits, or those of one server.
/// The chosen one carries the scope bar's accent and says so to
/// VoiceOver. At accessibility sizes the three stand one below the other:
/// in a row the last ran past the edge (measured at AX3), findable only by
/// scrolling.
struct MusicServerRow: View {
    let servers: [MusicServerChoice]
    let chosen: MusicSourceRule.Server?
    let choose: (MusicSourceRule.Server?) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { chips }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { chips }
                        .padding(.horizontal)
                }
            }
        }
        .accessibilityIdentifier("search-music-server-row")
    }

    @ViewBuilder
    private var chips: some View {
        chip(String(localized: "All"), isChosen: chosen == nil) { choose(nil) }
        ForEach(servers, id: \.self) { choice in
            chip(choice.name, isChosen: chosen == choice.server) { choose(choice.server) }
        }
    }

    private func chip(_ label: String, isChosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.subheadline.weight(isChosen ? .semibold : .regular))
                .foregroundStyle(isChosen ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isChosen ? AppTheme.accent.opacity(0.16) : Color.secondary.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
