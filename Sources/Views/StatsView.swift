// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
