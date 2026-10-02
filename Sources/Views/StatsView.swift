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
    /// Chart height follows the (now scaling) day labels.
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
                        Text("\(libraryViewModel.entries.filter { $0.progress?.countsAsFinished == true }.count)")
                    }
                }
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }

    /// Podcast shows by listening time. **Derived, not measured**. And the
    /// footer says so: the numbers come from the stored episode positions, so
    /// listening twice counts once and a deleted episode is missing. The
    /// alternative would be a new per-episode measurement that costs most of
    /// the shared iCloud budget and would still know nothing about the past.
    @ViewBuilder
    private var mostListenedShows: some View {
        let top = ListeningByClass.top(
            ListeningByClass.shows(positions: ListeningStore.positions(),
                                   showId: AppStorageKeys.podcastShowId(forEpisodeId:),
                                   excluding: ForeignMarks.importedIDs()),
            limit: Self.topLimit, atLeast: Double(Self.shortest))
        if !top.isEmpty {
            Section {
                ForEach(top, id: \.id) { entry in
                    rankedRow(PodcastShowSources.knownTitle(forShowId: entry.id)
                                  ?? String(localized: "Unknown Show"),
                              seconds: Int(entry.seconds))
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
    /// own seconds. So this section can say a plainer sentence than the one
    /// above.
    @ViewBuilder
    private var mostListenedStations: some View {
        let top = stats.topItems(limit: Self.topLimit, atLeast: Self.shortest,
                                 matching: ListeningClasses.isLive)
        if !top.isEmpty {
            Section {
                ForEach(top, id: \.id) { entry in
                    rankedRow(RadioStore.stationName(forId: entry.id)
                                  ?? String(localized: "Unknown Station"),
                              seconds: entry.seconds)
                }
            } header: {
                Text("Most Listened Stations")
            } footer: {
                Text("Measured while playing, on all your devices.")
            }
        }
    }

    private static let topLimit = 5
    /// Below a minute a "most listened" entry reads "0 min" and says
    /// nothing; it stays out and takes no place in the five.
    static let shortest = 60

    private func rankedRow(_ name: String, seconds: Int) -> some View {
        StatsRankedRow(name: name, duration: formatted(seconds))
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
                        // Fixed 9pt ignored Dynamic Type entirely.
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
        DurationText.length(seconds: Double(seconds))
    }
}

/// A ranked row: the name on the left, the duration always on the right.
/// `LabeledContent` put the value under a long name and beside a short one,
/// so the list changed shape row by row. A name is never an id: a
/// key nobody can read is not an answer, so an unresolvable entry says it
/// is unknown.
///
/// At an accessibility size a name beside the time shrank to a letter or
/// two (measured at AX3: "De ut…", "S …"), because the time keeps its whole
/// width. There the name takes the full line and the time stands on the
/// right below it.
struct StatsRankedRow: View {
    let name: String
    let duration: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    time
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: name)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    time.fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: some View {
        Text(verbatim: duration)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
