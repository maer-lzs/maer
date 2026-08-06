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
    /// own page, so the overview stays an overview. Kept as an alias route:
    /// it now lands on the parameterised source page (Paket 3).
    case allPopular
    /// Paket 3: one source's full page (fundgrube + the axis that carries).
    case source(CatalogSource)
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

/// Paket 4: push the catalog area from non-link surfaces (the search deck's
/// category tile) — same pattern as PushRadioRouteKey.
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
    /// Paket 1: the load layer lives in the store — one pass, all catalog
    /// sources, one visible failure per source. The page renders dumb.
    @ObservedObject private var store = FreeCatalogStore.shared
    @State private var detailItem: LibraryItem?
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    // Paket 4: the Apple radio-play charts moved here from the retired
    // HoerspielePage — 11be262 keeps the genre axis and the charts alive
    // ("alles andere bleibt gültig"); chip-driven, so legitimate view state
    // like the sub-pages' paging.
    @State private var selectedChip: String = CatalogGenreAxis.hoerspielChips[0].key
    @State private var chartResults: [PodcastSearchResult] = []
    @State private var chartsLoading = false
    @State private var chartsFailed = false

    private var rows: CatalogSourceLoader.SourceRows { store.sourceRows }
    private var languages: [String] { SuggestionLanguages.current() }

    // Paket 3: the genre-chip family moved to CatalogSourcePage — the
    // control sits on the surface it acts on (48e786d decision), and the
    // overview stays an overview.

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
                chartsSection
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
                Text("Public-broadcast content can disappear after fixed periods — downloads keep your copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Free Audiobooks & Radio Plays"))
        .task { await store.ensureSourcesLoaded() }
        .task(id: selectedChip) { await loadCharts() }
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
                RowHeading.entry(verbatim: source.title,
                                 destination: FreeAudiobooksRoute.source(source))
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

    // Paket 3: the separate "Show all" link died with the heading chevron —
    // one affordance, one target (no journey held the old identifier;
    // the earlier comment claiming one was my own stale assumption).
    @ViewBuilder
    private var librivoxSection: some View {
        tileSection(.librivox, items: rows.librivoxPopular)
    }

    private func tileRow(_ items: [LibraryItem], placeholder: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
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


    // ── Apple radio-play charts (moved from HoerspielePage, Paket 4) ──────

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
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.plain("Podcast Charts (Apple)")
            chipRow
            if chartsLoading && chartResults.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if chartResults.isEmpty {
                Text(chartsFailed
                     ? String(localized: "The charts could not be loaded. Check your connection.")
                     : String(localized: "Nothing in this genre right now."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(chartResults, id: \.feedURL) { result in
                        CatalogFeedRow(result: result)
                    }
                }
            }
        }
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
        // Subscribed shows drop out — a catalog, not a second library view.
        let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
        chartResults = PodcastRecommendationsStore.excludingSubscribed(
            pool,
            subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
            subscribedTitles: shows.map(\.title))
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
