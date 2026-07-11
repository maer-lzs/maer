import SwiftUI

/// Lokale Hörstatistik: Hörzeit heute/7 Tage/gesamt, Balken der letzten
/// 14 Tage (eigene Capsules, kein Chart-Framework), Tage-Serie und Anzahl
/// abgeschlossener Bücher. Daten kommen aus dem ListeningStatsStore.
struct StatsView: View {
    @ObservedObject private var stats = ListeningStatsStore.shared
    var libraryViewModel: LibraryViewModel?

    var body: some View {
        Form {
            Section("Listening Time") {
                LabeledContent("Today") { Text(formatted(stats.seconds(on: Date()))) }
                LabeledContent("Last 7 Days") { Text(formatted(stats.seconds(lastDays: 7))) }
                LabeledContent("Total") { Text(formatted(stats.totalSeconds())) }
            }

            Section("Last 14 Days") {
                barChart
                    .frame(height: 120)
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
    }

    /// Schlichte Capsule-Balken; Wochenend-/Tagesbeschriftung nur unter
    /// jedem zweiten Balken, damit nichts kollidiert.
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
                        .font(.system(size: 9))
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
