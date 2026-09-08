// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// The ONE merged catalog page. "Freie Hörbücher & Hörspiele". Radio-play
/// feeds and public-domain catalogs share the surface; the German split
/// Hörspiel/Hörbuch is not one the directories know, so the SOURCE is the
/// ordering axis (one row per source). The ACTION
/// carries the remaining distinction: feed rows subscribe, catalog tiles play.
nonisolated enum FreeAudiobooksRoute: Hashable {
    case area
    /// The endless browsing of the LibriVox popularity list. Its
    /// own page, so the overview stays an overview. Kept as an alias route:
    /// it now lands on the parameterised source page.
    case allPopular
    /// One source's full page (fundgrube + the axis that carries).
    case source(CatalogSource)
    /// The endless "Popular" browsing of ONE source. It left the
    /// overview when the user decided that page is rows only. The scrolling
    /// did not disappear, it moved to where scrolling is the form.
    case popular(CatalogSource)
    /// H erweitert: one shelf of a genre-carrying source. The
    /// full grid behind a genre row (shelf = FILTER over the source's stock,
    /// no second client).
    case shelf(CatalogSource, String)
    /// The SHOW PAGE of an archive.org series bundle. The class is
    /// read from the item's own collections (`ArchiveItemForm`). Tap stays
    /// NACHSCHLAGEN; the page replaces the detail sheet for this class only.
    case series(itemId: String)
    /// X²·3: the OERR sub-page. One tile row per COUNTRY (empty countries
    /// do not appear).
    case oerrCountries
    /// The ONE book detail page for a catalog title. Carries the id only:
    /// a catalog id is self-describing, the session cache resolves it on
    /// demand (the queue rows follow the same rule).
    case catalogBook(itemId: String)
}

/// Push the catalog area from non-link surfaces (the search deck's
/// category tile). Same pattern as PushRadioRouteKey.
nonisolated struct PushFreeAudiobooksRouteKey: EnvironmentKey {
    static let defaultValue: @MainActor (FreeAudiobooksRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var pushFreeAudiobooksRoute: @MainActor (FreeAudiobooksRoute) -> Void {
        get { self[PushFreeAudiobooksRouteKey.self] }
        set { self[PushFreeAudiobooksRouteKey.self] = newValue }
    }
}

struct FreeAudiobooksPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Serverless, the audiobooks TAB shows this page's sections as
    /// its core. Embedded, the host provides scroll and title, and there is
    /// exactly ONE version of the sections (parameterised, not copied).
    var embedded = false
    /// X²·3: re-render when the live OERR entries land (calm-gated).
    @ObservedObject private var oerrStore = OERRLiveStore.shared
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    /// The load layer lives in the store. One pass, all catalog
    /// sources, one visible failure per source. The page renders dumb.
    @ObservedObject private var store = FreeCatalogStore.shared
    @Environment(\.isOnline) private var isOnline
    // The radio-play charts moved here from the retired standalone page;
    // genre axis and charts stay alive. Chip-driven, so legitimate view
    // state like the sub-pages' paging.
    //
    // Why only the radio-play charts and no book charts, measured, so the
    // book row does not return in three months: the FICTION categories are
    // FORM-based (Drama 1484, SciFi 1485, Comedy Fiction 1486) and hold
    // genuine radio plays. `Books` 1482 is TOPIC-based instead: 20 of 25
    // chart entries were conversations ABOUT books rather than readings.
    // Filtering a form out of a topic category would mean guessing, and even
    // a perfect filter would leave only the five readings that
    // LibriVox, Gutenberg and archive.org cover better anyway.
    @State private var selectedChip: String = CatalogGenreAxis.hoerspielChips[0].key
    @State private var chartResults: [PodcastSearchResult] = []
    @State private var chartsLoading = false
    @State private var chartsFailed = false
    /// X²·5: the second chart row. Apple's book category (genre 1482;
    /// readings and literature adaptations live there). Loads once, not
    /// chip-driven.

    private var rows: CatalogSourceLoader.SourceRows { store.sourceRows }
    private var languages: [String] { SuggestionLanguages.current() }

    // The genre-chip family moved to CatalogSourcePage. The control sits
    // on the surface it acts on, and the overview stays an overview.

    private var catalogRowsEmpty: Bool {
        rows.librivoxPopular.isEmpty && rows.archiveBooks.isEmpty
            && rows.gutenberg.isEmpty && rows.oldTimeRadio.isEmpty
    }

    var body: some View {
        if embedded {
            sectionStack
                .task { await store.ensureSourcesLoaded() }
                .task { await OERRLiveStore.shared.ensureLoaded(forLanguages: languages) }
                .task(id: selectedChip) { await loadCharts() }
                .onChange(of: isOnline) { _, connected in
                    if connected { Task { await store.ensureSourcesLoaded() } }
                }
        } else {
            standalone
        }
    }

    private var standalone: some View {
        ScrollView {
            sectionStack
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
        }
        .navigationTitle(Text("Audiobooks and Radio Plays"))
        .task { await store.ensureSourcesLoaded() }
        .task { await OERRLiveStore.shared.ensureLoaded(forLanguages: languages) }
        .task(id: selectedChip) { await loadCharts() }
        // Connection returns while the page is open: load then.
        .onChange(of: isOnline) { _, connected in
            if connected { Task { await store.ensureSourcesLoaded() } }
        }
    }

    private var sectionStack: some View {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // The rights bases differ per source. The capsule per title
                // says which; this line only names the FAMILIES.
                Text("From public broadcasters, independent studios and open catalogs. Separate from your own library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                // Reihenfolge: feeds first, catalogs after.
                // The feed rows are static curation and render instantly.
                feedSection(.oerr)
                feedSection(.independents)
                if AppStorageKeys.appleCatalogEnabledValue { chartsSection }
                tileSection(.oldTimeRadio, items: rows.oldTimeRadio,
                            placeholder: "waveform.and.mic")
                librivoxSection
                tileSection(.archiveBooks, items: rows.archiveBooks)
                tileSection(.gutenberg, items: rows.gutenberg)
                if catalogRowsEmpty {
                    // Every state below ENDS. Spinner only while the
                    // pass actually runs; an empty result and a failed run
                    // each get an honest line with a way back in.
                    if store.sourcesLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if !isOnline {
                        Text("The catalogs need a connection.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if !store.sourcesFailures.isEmpty {
                        Text("The catalogs could not be loaded. Tap to try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onTapGesture { Task { await store.retrySources() } }
                            .accessibilityIdentifier("freecat-sources-retry")
                    } else if !store.sourcesLoaded {
                        // Ran cleanly, found nothing (language filter can do
                        // this). The exact case that used to spin forever.
                        Text("Nothing found in the catalogs right now. Tap to try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onTapGesture { Task { await store.retrySources() } }
                            .accessibilityIdentifier("freecat-sources-retry-empty")
                    } else {
                        // Loaded, rows still riding the calm gate. Moments.
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                Text("Public-broadcast content can disappear after fixed periods. Downloads keep your copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
    }

    /// Feed sources are TILE rows too. The list form belongs to
    /// search, the surface speaks ONE tile language. The action distinction
    /// lives in the tap convention now (tile tap = show preview =
    /// NACHSCHLAGEN; subscribing happens there). Hang risk assessed:
    /// this page is pushed, not a kept-alive tab root.
    @ViewBuilder
    private func feedSection(_ source: CatalogSource) -> some View {
        let feeds = OERRLiveStore.feeds(for: source, languages: languages)
        if !feeds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if source == .oerr {
                    // X²·3: the rule-curated row grows past the preview. The
                    // counted chevron opens the BY-COUNTRY sub-page.
                    RowHeading(title: "", verbatimTitle: source.title,
                               total: feeds.count,
                               shown: RowPreview.cut(feeds).count,
                               destination: FreeAudiobooksRoute.oerrCountries)
                    feedTileRow(Array(RowPreview.cut(feeds)))
                } else {
                    RowHeading.plain(verbatim: source.title)
                    feedTileRow(feeds)
                }
            }
        }
    }

    private func feedTileRow(_ feeds: [HoerspielCuration.Entry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(feeds) { entry in
                    // X²·1: form meta line + CC capsule only where the feed
                    // states it.
                    RecommendationTile(result: PodcastSearchResult(
                        title: entry.title, author: entry.author,
                        artworkURL: entry.artworkURL, feedURL: entry.feedURL),
                        subtitle: entry.form?.label,
                        badgeText: entry.ccLicense)
                        .cardRowSlot()
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    /// A catalog source: preview tile row. An EMPTY row with a recorded
    /// failure shows the reason instead of silently missing.
    @ViewBuilder
    private func tileSection(_ source: CatalogSource, items: [LibraryItem],
                             placeholder: String = "book.closed") -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.entry(verbatim: source.title,
                                 destination: FreeAudiobooksRoute.source(source))
                tileRow(items, placeholder: placeholder)
            }
        } else if rows.failures[source] != nil {
            // The reason itself stays in the log; the surface says what
            // happened and offers the way back.
            failureLine(source)
        }
    }

    /// The error line is TAPPABLE (retry. "unreachable" is a normal
    /// state for these sources and needs a visible way back, not a dead-end
    /// label) and carries the short REASON, so one look tells 429 / HTML
    /// answer / transport apart.
    private func failureLine(_ source: CatalogSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RowHeading.plain(verbatim: source.title)
            Button {
                Task { await store.retrySources() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    // The SENTENCE is for the reader; the technical reason
                    // goes to the log (it is written there already, with
                    // source and page). "(URLError -1004)" on a user
                    // surface is a developer talking to himself, and it is
                    // the same rule the other failure lines already follow.
                    Text("Could not load \(source.title). Tap to try again.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    // The separate "Show all" link died with the heading chevron. One
    // affordance, one target.
    @ViewBuilder
    private var librivoxSection: some View {
        tileSection(.librivox, items: rows.librivoxPopular)
    }

    private func tileRow(_ items: [LibraryItem], placeholder: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    tile(item, placeholder: placeholder)
                        .cardRowSlot(spacing: 14)
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }


    // ── Radio-play charts ───────────────────────────────────────────────

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CatalogGenreAxis.hoerspielChips) { chip in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { selectedChip = chip.key }
                    } label: {
                        chipLabel(chip, selected: selectedChip == chip.key)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hoerspiele-chip-\(chip.key)")
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func chipLabel(_ chip: CatalogGenreAxis.Chip, selected: Bool) -> some View {
        let fill: AnyShapeStyle = selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
        let text: Color = selected ? .white : .primary
        return Label(chip.title, systemImage: chip.systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fill, in: Capsule())
            .foregroundStyle(text)
    }

    @ViewBuilder
    private var chartsSection: some View {
        SwitchableTileRow(
            state: chartsLoading && chartResults.isEmpty ? .loading
                : (chartResults.isEmpty ? (chartsFailed ? .failed : .empty) : .ready),
            senderLine: "Apple Podcasts",
            emptyText: "Nothing in this genre right now.",
            failedText: "The charts could not be loaded. Check your connection."
        ) {
            // Same three levels as the 78s
            // row. The head means the AREA (charts overview, chevron
            // earned by the page's existence), the chips switch in place,
            // and the genre LINE below leads counted into the active
            // genre's chart page.
            RowHeading.entry("Popular Radio-Play Podcasts", destination: PodcastRoute.charts)
        } selector: {
            chipRow
            RowHeading(title: "", verbatimTitle: activeChipTitle,
                       font: .headline,
                       total: chartResults.count,
                       shown: RowPreview.cut(chartResults).count,
                       destination: PodcastRoute.chartGenre(selectedChip))
        } content: {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(RowPreview.cut(chartResults), id: \.feedURL) { result in
                        RecommendationTile(result: result)
                            .cardRowSlot()
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }

    private var activeChipTitle: String {
        CatalogGenreAxis.hoerspielChips.first(where: { $0.key == selectedChip })?.title ?? ""
    }

    private func loadCharts() async {
        guard let chip = CatalogGenreAxis.hoerspielChips.first(where: { $0.key == selectedChip })
        else { return }
        chartsLoading = true
        chartsFailed = false
        defer { chartsLoading = false }
        #if DEBUG
        if UITestSeed.isActive { chartResults = []; return }
        #endif
        guard AppStorageKeys.appleCatalogEnabledValue else {
            // Apple off: the chart section falls away honestly. These charts
            // have no second source (measured in the PI pre-check: overlap ~0).
            chartResults = []
            chartsFailed = false
            return
        }
        let directory = ITunesDirectory()
        var pool: [PodcastSearchResult] = []
        for genreId in chip.genreIds {
            guard let hits = try? await directory.topPodcasts(genreId: genreId) else {
                Logger.library.notice("FREECAT charts chip=\(chip.key, privacy: .public) genre=\(genreId) FAILED")
                continue
            }
            pool += hits
        }
        chartsFailed = pool.isEmpty
        // Subscribed shows drop out. A catalog, not a second library view.
        let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
        chartResults = PodcastRecommendationsStore.excludingSubscribed(
            pool,
            subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
            subscribedTitles: shows.map(\.title))
    }

    private func tile(_ item: LibraryItem, placeholder: String = "book.closed") -> some View {
        // NACHSCHLAGEN. Tap opens the detail (rights line + the
        // prominent Play); long-press keeps Play as the shortcut.
        // An OTR series bundle looks up its SHOW PAGE (episode
        // list) instead of the sheet. Same tap class, richer answer.
        FreeCatalogBookTile(
            item: item,
            placeholderSystemImage: placeholder,
            onTap: {
                if FreeCatalogProvider.shared.hasPartsList(itemId: item.id) {
                    pushFreeAudiobooksRoute(.series(itemId: item.id))
                } else {
                    pushFreeAudiobooksRoute(.catalogBook(itemId: item.id))
                }
            }
        )
        .contextMenu {
            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: { Label("Play", systemImage: "play.fill") }
        }
    }
}

/// X²·3: the public-broadcast sub-page, one tile row per COUNTRY (the
/// scaffolding blueprint with the country as the axis; empty countries do
/// not appear. DIE REGEL). Entries come from the same live store the
/// preview row reads.
struct OERRCountriesPage: View {
    @ObservedObject private var store = OERRLiveStore.shared

    private var languages: [String] { SuggestionLanguages.current() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                let entries = store.current(forLanguages: languages)
                ForEach(OERRCuration.Country.allCases, id: \.self) { country in
                    let rows = entries.filter { $0.country == country }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeading.plain(verbatim: country.title)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(rows) { entry in
                                        RecommendationTile(result: PodcastSearchResult(
                                            title: entry.title, author: entry.author,
                                            artworkURL: entry.artworkURL, feedURL: entry.feedURL))
                                            .cardRowSlot()
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                    }
                }
                Text("Public-broadcast content can disappear after fixed periods. Downloads keep your copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: CatalogSource.oerr.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await OERRLiveStore.shared.ensureLoaded(forLanguages: languages) }
    }
}
