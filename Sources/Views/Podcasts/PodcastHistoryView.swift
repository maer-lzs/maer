// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The chronological listen history over the show-independent
/// PodcastListenLog. Newest play first, tombstones (marked unplayed)
/// hidden. A row taps into the episode WHEN it still resolves (subscribed
/// feed still carries the guid); an unresolvable one renders plain. The
/// log outlives unsubscribes by design, no false affordance.
struct PodcastHistoryView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var entries: [PodcastListenLog.Entry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No listening history yet", systemImage: "checkmark.circle")
                } description: {
                    Text("Episodes you finish appear here, even after you unsubscribe from a show.")
                }
            } else {
                List(entries, id: \.guid) { entry in
                    row(entry)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(Text("Listening History"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { entries = PodcastListenLog.shared.history() }
    }

    @ViewBuilder
    private func row(_ entry: PodcastListenLog.Entry) -> some View {
        // Resolvable = the guid is still reachable as an episode (RSS feed
        // still subscribed and carrying it, or an ABS episode id).
        let resolvable = PodcastSubscriptions.shared.feedURL(forEpisodeId: entry.guid) != nil
        if resolvable {
            NavigationLink(value: PodcastRoute.episode(itemId: entry.guid)) {
                rowContent(entry)
            }
        } else {
            rowContent(entry)
        }
    }

    private func rowContent(_ entry: PodcastListenLog.Entry) -> some View {
        HistoryRow(title: entry.episodeTitle, subtitle: entry.showTitle, date: PodcastListenLog.shownDate(entry))
    }
}
