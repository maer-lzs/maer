// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import OSLog

/// 8d49a8e: the radio-play page under Podcasts. Two sources, honestly
/// separated: the genre CHARTS (Apple, keyless — where the bulk lives) and
/// the curated SOCKET of feeds that no directory carries. Catalog, not
/// library: nothing here is subscribed until the user taps subscribe.
struct HoerspielePage: View {
    let playerCoordinator: PlayerCoordinator
    @Environment(\.pushPodcastRoute) private var pushRoute

    @State private var selectedChip: String = CatalogGenreAxis.hoerspielChips[0].key
    @State private var results: [PodcastSearchResult] = []
    @State private var loading = false
    @State private var loadFailed = false
    @State private var oldTimeRadio: [LibraryItem] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                chipRow
                chartSection
                curatedSection
                oldTimeRadioSection
                crossLink
                footnote
            }
            .padding(.vertical)
        }
        .navigationTitle("Radio Plays")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task(id: selectedChip) { await load() }
        .task { await loadOldTimeRadio() }
    }

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
                    .accessibilityIdentifier("hoerspiel-chip-\(chip.key)")
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    /// Own function: the inline ternaries made the chip row a type-check
    /// hot spot (compiler timeout), and a card label is worth a name anyway.
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
    private var chartSection: some View {
        if loading && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if results.isEmpty {
            // Honest empty state — a chart can be thin, and offline is a
            // reason the user can act on.
            Text(loadFailed
                 ? String(localized: "The charts could not be loaded. Check your connection.")
                 : String(localized: "Nothing in this genre right now."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            ForEach(results, id: \.feedURL) { result in
                catalogRow(result)
            }
        }
    }

    /// The curated socket: feeds no directory lists. Stays a SEPARATE section
    /// so it is obvious these are our picks, not a chart.
    @ViewBuilder
    private var curatedSection: some View {
        if !HoerspielCuration.feeds.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Editorial picks")
                    .font(.headline)
                    .padding(.horizontal)
                ForEach(HoerspielCuration.feeds) { entry in
                    catalogRow(PodcastSearchResult(title: entry.title, author: entry.author,
                                                   artworkURL: nil, feedURL: entry.feedURL))
                }
            }
            .padding(.top, 6)
        }
    }

    /// e948444: the Old-Time-Radio shelf — only licence-stated items, the
    /// licence visible per title. English stock, so it only shows when
    /// English is among the suggestion languages: the other catalog rows
    /// follow the same rule, and a German-only user should not be handed a
    /// shelf they cannot use.
    @ViewBuilder
    private var oldTimeRadioSection: some View {
        if SuggestionLanguages.current().contains("en"), !oldTimeRadio.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Radio Play Classics (English)")
                    .font(.headline)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(oldTimeRadio) { item in
                            FreeCatalogBookTile(
                                item: item,
                                placeholderSystemImage: "waveform.and.mic",
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
        }
    }

    private func catalogRow(_ result: PodcastSearchResult) -> some View {
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

    /// G8: only offered because the target page really exists and is reachable.
    private var crossLink: some View {
        NavigationLink(value: FreeAudiobooksRoute.area) {
            HStack {
                Label("Also interesting: Free Audiobooks", systemImage: "books.vertical")
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hoerspiele-crosslink")
    }

    private var footnote: some View {
        Text("Public-broadcast content can disappear after fixed periods — downloads keep your copies.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
    }

    private func loadOldTimeRadio() async {
        guard oldTimeRadio.isEmpty, SuggestionLanguages.current().contains("en") else { return }
        #if DEBUG
        if UITestSeed.isActive { return }
        #endif
        do {
            let docs = try await ArchiveOrgClient.popularOldTimeRadio(rows: 12)
            let provider = FreeCatalogProvider.shared
            oldTimeRadio = docs.compactMap { doc in
                guard let identifier = doc.identifier else { return nil }
                // The series bundles are legitimate here — mark them so the
                // plausibility gate uses the higher bound (e948444).
                provider.rememberOldTimeRadio(identifier)
                return provider.remember(popular: doc)
            }
            Logger.rss.notice("HOERSPIELE otr loaded=\(docs.count) shown=\(self.oldTimeRadio.count)")
        } catch {
            Logger.rss.notice("HOERSPIELE otr FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    private func load() async {
        guard let chip = CatalogGenreAxis.hoerspielChips.first(where: { $0.key == selectedChip })
        else { return }
        loading = true
        loadFailed = false
        defer { loading = false }
        #if DEBUG
        if UITestSeed.isActive { results = []; return }
        #endif
        let directory = ITunesDirectory()
        var pool: [PodcastSearchResult] = []
        for genreId in chip.genreIds {
            guard let hits = try? await directory.topPodcasts(genreId: genreId) else {
                Logger.rss.notice("HOERSPIELE chip=\(chip.key, privacy: .public) genre=\(genreId) FAILED")
                continue
            }
            Logger.rss.notice("HOERSPIELE chip=\(chip.key, privacy: .public) genre=\(genreId) hits=\(hits.count)")
            pool += hits
        }
        loadFailed = pool.isEmpty
        // Subscribed shows drop out — this is a catalog, not a second view of
        // the library (fb94905 rule, feed URL and show identity).
        let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
        results = PodcastRecommendationsStore.excludingSubscribed(
            pool,
            subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
            subscribedTitles: shows.map(\.title))
    }
}
