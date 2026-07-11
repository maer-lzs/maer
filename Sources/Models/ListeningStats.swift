import Foundation
import Combine

/// Rohdaten der lokalen Hörstatistik: Sekunden pro Kalendertag
/// ("yyyy-MM-dd", lokale Zeitzone). Bewusst simpel — JSON in Documents.
nonisolated struct ListeningStatsData: Codable {
    var secondsPerDay: [String: Int] = [:]
}

/// Erfasst Hörzeit (1-Sekunden-Ticks aus dem Player-Zeitbeobachter) und
/// beantwortet die Fragen der Statistik-Seite. Disk-Writes gedrosselt und
/// im Hintergrund — das Ticken darf nichts kosten.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    @Published private(set) var data: ListeningStatsData

    private var lastSaveAt: TimeInterval = 0
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("listening_stats.json")

    private init() {
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ListeningStatsData.self, from: raw) {
            data = decoded
        } else {
            data = ListeningStatsData()
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Vom Player-Tick (1×/s bei laufender Wiedergabe): Hörzeit auf heute
    /// buchen; auf Disk höchstens alle 30 s.
    func addSeconds(_ seconds: Int) {
        data.secondsPerDay[Self.dayKey(for: Date()), default: 0] += seconds
        let now = Date().timeIntervalSince1970
        if now - lastSaveAt >= 30 {
            lastSaveAt = now
            save()
        }
    }

    /// Bei Pause/Stop: verbleibende Sekunden sofort sichern.
    func flush() {
        save()
    }

    private func save() {
        let snapshot = data
        let url = fileURL
        Task.detached(priority: .utility) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
    }

    // MARK: - Abfragen

    func seconds(on date: Date) -> Int {
        data.secondsPerDay[Self.dayKey(for: date)] ?? 0
    }

    func totalSeconds() -> Int {
        data.secondsPerDay.values.reduce(0, +)
    }

    func seconds(lastDays days: Int) -> Int {
        dailySeconds(lastDays: days).reduce(0) { $0 + $1.seconds }
    }

    /// Älteste zuerst — direkt als Balkenreihe darstellbar.
    func dailySeconds(lastDays days: Int) -> [(date: Date, seconds: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, seconds(on: day))
        }
    }

    /// Tage am Stück mit Hörzeit, bis heute (ein hörfreier heutiger Tag
    /// bricht die Serie noch nicht — gezählt wird ab gestern rückwärts).
    func currentStreak() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var streak = seconds(on: today) > 0 ? 1 : 0
        var offset = 1
        while let day = calendar.date(byAdding: .day, value: -offset, to: today),
              seconds(on: day) > 0 {
            streak += 1
            offset += 1
        }
        return streak
    }
}
