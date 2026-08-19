// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Local listening stats: listening time today/7 days/total, bars of the last
/// 14 days (own capsules, no chart framework), day streak and number of finished
/// books. Data comes from the ListeningStatsStore.
struct StatsView: View {
    @ObservedObject private var stats = ListeningStatsStore.shared
    var libraryViewModel: LibraryViewModel?
    /// D14/B13: chart height follows the (now scaling) day labels.
    @ScaledMetric(relativeTo: .caption2) private var chartHeight: CGFloat = 120

    var body: some View {
        Form {
            Section("Listening Time") {
                LabeledContent("Today") { Text(formatted(stats.seconds(on: Date()))) }
                LabeledContent("Last 7 Days") { Text(formatted(stats.seconds(lastDays: 7))) }
                LabeledContent("Total") { Text(formatted(stats.totalSeconds())) }
            }

            Section("Last 14 Days") {
                barChart
                    .frame(height: chartHeight)
                    .padding(.vertical, 4)
            }

            mostListenedShows
            mostListenedStations

            Section {
                LabeledContent("Days in a Row") {
                    Label("\(stats.currentStreak())", systemImage: "flame.fill")
                        .foregroundStyle(stats.currentStreak() > 0 ? AppTheme.accent : .secondary)
                }
                if let libraryViewModel {
                    LabeledContent("Finished Books") {
                        Text("\(libraryViewModel.entries.filter { $0.progress?.isFinished == true }.count)")
                    }
                }
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }

    /// Podcast shows by listening time. **Derived, not measured** — and the
    /// footer says so: the numbers come from the stored episode positions, so
    /// listening twice counts once and a deleted episode is missing. The
    /// alternative would be a new per-episode measurement that costs most of
    /// the shared iCloud budget and would still know nothing about the past.
    @ViewBuilder
    private var mostListenedShows: some View {
        let top = ListeningByClass.top(
            ListeningByClass.shows(in: UserDefaults.standard.dictionaryRepresentation(),
                                   showId: AppStorageKeys.podcastShowId(forEpisodeId:)),
            limit: Self.topLimit)
        if !top.isEmpty {
            Section {
                ForEach(top, id: \.id) { entry in
                    LabeledContent {
                        Text(formatted(Int(entry.seconds)))
                    } label: {
                        Text(verbatim: showTitle(entry.id))
                    }
                }
            } header: {
                Text("Most Listened Shows")
            } footer: {
                Text("Estimated from your saved positions: listening again does not count twice, and episodes that left the feed are missing.")
            }
        }
    }

    /// Radio stations by MEASURED listening time. A live stream has no position
    /// to derive from, which is exactly why it is the one class that gets its
    /// own seconds — so this section can say a plainer sentence than the one
    /// above.
    @ViewBuilder
    private var mostListenedStations: some View {
        let top = stats.topItems(limit: Self.topLimit, matching: ListeningClasses.isLive)
        if !top.isEmpty {
            Section {
                ForEach(top, id: \.id) { entry in
                    LabeledContent {
                        Text(formatted(entry.seconds))
                    } label: {
                        Text(verbatim: RadioStore.station(forId: entry.id)?.name ?? entry.id)
                    }
                }
            } header: {
                Text("Most Listened Stations")
            } footer: {
                Text("Measured while playing, on all your devices.")
            }
        }
    }

    private static let topLimit = 5

    /// The show's name where it is known — a raw id would be a number nobody
    /// asked for, so an unresolvable entry keeps its id rather than pretending.
    private func showTitle(_ showId: String) -> String {
        PodcastSubscriptions.shared.shows.first { $0.id == showId }?.title ?? showId
    }

    /// Plain capsule bars; weekday/day label only under every other bar so
    /// nothing collides.
    private var barChart: some View {
        let days = stats.dailySeconds(lastDays: 14)
        let maxSeconds = max(days.map(\.seconds).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(day.seconds > 0 ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.quaternary))
                        .frame(height: max(4, CGFloat(day.seconds) / CGFloat(maxSeconds) * 90))
                        .frame(maxHeight: 90, alignment: .bottom)
                    Text(index % 2 == 0 ? day.date.formatted(.dateTime.day()) : " ")
                        // D14/B13: fixed 9pt ignored Dynamic Type entirely.
                        .font(.caption2)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatted(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min") }
        return String(localized: "\(minutes) min")
    }
}
