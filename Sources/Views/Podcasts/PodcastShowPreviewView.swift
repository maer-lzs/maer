// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Y2b: TEMPORARY preview of a not-yet-subscribed show. Aggregates what is
/// available WITHOUT a subscription: catalog metadata (the recommendation
/// pool's entry, when still present) plus the LIVE-fetched RSS feed (cover,
/// description, episode list). Nothing is persisted until the subscribe
/// button is used; leaving the page discards everything. Deliberately no
/// listen-preview: the RSS provider only streams subscribed episodes.
struct PodcastShowPreviewView: View {
    let feedURL: String

    @State private var show: PodcastShow?
    @State private var failed = false

    /// Catalog seed (title/artwork) while the feed loads. Best effort, the
    /// pool may have rotated since the tile was rendered.
    private var catalogResult: PodcastSearchResult? {
        PodcastRecommendationsStore.shared.results.first {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL)
                == PodcastSubscriptions.normalizeFeedURL(feedURL)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                PodcastSubscribeButton(feedURL: feedURL)
                    .padding(.horizontal)
                if let description = show?.description, !description.isEmpty {
                    Text(podcastPlainText(description))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                episodeList
                if failed {
                    ContentUnavailableView(
                        "The feed could not be loaded.",
                        systemImage: "wifi.exclamationmark"
                    )
                    .padding(.top, 24)
                } else if show == nil {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(show?.title ?? catalogResult?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .reportsBottomBarScroll()
        .task {
            guard let url = PodcastFeedAddress.requestURL(feedURL) else { failed = true; return }
            if let fetched = await PodcastSubscriptions.fetchAndParse(feedURL: url) {
                show = fetched
            } else {
                failed = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            podcastArtwork(
                url: (show?.artworkURL ?? catalogResult?.artworkURL).flatMap { URL(string: $0) },
                size: 140, corner: 18)
            Text(show?.title ?? catalogResult?.title ?? "")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if let author = show?.author ?? catalogResult?.author, !author.isEmpty {
                Text(author).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var episodeList: some View {
        if let episodes = show?.episodes, !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Episodes").font(.headline).padding(.horizontal)
                ForEach(episodes.prefix(25), id: \.guid) { episode in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(episodeMeta(episode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    Divider().padding(.leading)
                }
            }
        }
    }

    private func episodeMeta(_ episode: PodcastEpisode) -> String {
        var parts: [String] = []
        if episode.pubDate > 0 {
            parts.append(Date(timeIntervalSince1970: episode.pubDate / 1000)
                .formatted(.relative(presentation: .named)))
        }
        if episode.duration > 0 {
            parts.append(Duration.seconds(episode.duration)
                .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        return parts.joined(separator: " · ")
    }
}
