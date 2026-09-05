// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Raw local listening stats: seconds per calendar day ("yyyy-MM-dd", local
/// time zone). Deliberately simple. JSON in Documents.
nonisolated struct ListeningStatsData: Codable, Equatable {
    var secondsPerDay: [String: Int] = [:]
    /// The same seconds, seen per ITEM. A DIMENSION of the day pot, never a
    /// second count: both are fed by the one tick, so the item sums can only
    /// ever be a subset of the day sums (a tick without a known id lands in the
    /// day pot alone). Anything else would be two truths for one question.
    var secondsPerItem: [String: Int] = [:]

    init(secondsPerDay: [String: Int] = [:], secondsPerItem: [String: Int] = [:]) {
        self.secondsPerDay = secondsPerDay
        self.secondsPerItem = secondsPerItem
    }

    /// Hand-written, and the reason is a trap rather than a preference: the
    /// SYNTHESISED decoder requires every key, and a property default does not
    /// make one optional. Adding a field to a stored type is therefore a silent
    /// migration. The file already on disk would stop decoding, the store
    /// would fall back to empty, and every existing history would be gone
    /// without an error anywhere. A missing field means "this pot did not exist
    /// yet", which is empty, not undecodable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        secondsPerDay = try container.decodeIfPresent([String: Int].self, forKey: .secondsPerDay) ?? [:]
        secondsPerItem = try container.decodeIfPresent([String: Int].self, forKey: .secondsPerItem) ?? [:]
    }
}

/// Records listening time (1-second ticks from the player time observer) and
/// answers the stats page's questions. Disk writes throttled and in the
/// background. Ticking must cost nothing.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = ListeningStatsStore()

    /// THIS device's numbers. The file on disk. Every question about totals
    /// goes through `data` below, which adds the other devices.
    @Published private(set) var ownData: ListeningStatsData

    /// What the surfaces read: this device plus every other device's published
    /// pot. Summed on READ, never on write.
    private(set) var data: ListeningStatsData

    /// Other devices' pots as last seen. Refreshed when iCloud reports a
    /// change; kept as a value so a read never touches the store.
    private var foreign: [String: ListeningStatsData] = [:]

    /// How many items the pot keeps. 500 radio stations cost ~6 % of the shared
    /// iCloud budget; the cap is what keeps that a ceiling instead of a hope.
    static let itemPotCap = 500

    private var lastSaveAt: TimeInterval = 0
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("listening_stats.json")

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("listening_stats.json")
        let loaded: ListeningStatsData
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ListeningStatsData.self, from: raw) {
            loaded = decoded
        } else {
            loaded = ListeningStatsData()
        }
        ownData = loaded
        data = loaded
    }

    /// The MIGRATION the order asks for. And it is deliberately a no-op by
    /// construction: the existing local file IS this device's pot, so nothing
    /// has to move and nothing can be lost on the way. The one-time step is
    /// only that the file gets PUBLISHED, which `start()` does.
    ///
    /// The other direction is the one that needs care: a device whose file is
    /// gone (a reset, a failed write) but whose pot still stands in iCloud
    /// adopts its own numbers back instead of starting at zero. Presence is
    /// checked, nothing is written blind, and a second run changes nothing
    /// because the file then exists.
    func start() {
        ListeningStatsCloudSync.shared.start()
        let ownPot = ListeningStatsCloudSync.shared.foreignPots()[SyncHistoryStore.deviceId]
        if ownData.secondsPerDay.isEmpty, let ownPot, !ownPot.secondsPerDay.isEmpty {
            Logger.library.notice("listening stats: local file empty, adopting this device's own iCloud pot (\(ownPot.secondsPerDay.count) days)")
            ownData = ownPot
            save()
        }
        cloudChanged()
    }

    /// Re-read the other devices and recompose the totals.
    func cloudChanged() {
        foreign = ListeningStatsCloudSync.shared.foreignPots()
        recompose()
    }

    private func recompose() {
        data = ListeningStatsSync.merged(local: ownData,
                                         ownDeviceId: SyncHistoryStore.deviceId,
                                         foreign: foreign)
        objectWillChange.send()
    }

    /// The day key is STORED data, so it must not depend on the device.
    /// Without a fixed locale a non-Gregorian calendar (Buddhist, Japanese and
    /// others are selectable in iOS settings) formats the same instant as a
    /// different year: the statistics would split into two key spaces and a
    /// calendar change would orphan the history.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// From the player tick (1×/s while playing): add listening time to today
    /// and, when the caller knows which item is running, to that item as well.
    /// Persist to disk at most every 30 s.
    ///
    /// ONE call for both pots. A second entry point would be a second way to
    /// count, and two counters for one second is exactly how they drift apart.
    func addSeconds(_ seconds: Int, itemId: String? = nil) {
        ownData.secondsPerDay[Self.dayKey(for: Date()), default: 0] += seconds
        if let itemId, !itemId.isEmpty {
            ownData.secondsPerItem[itemId, default: 0] += seconds
        }
        recompose()
        let now = Date().timeIntervalSince1970
        if now - lastSaveAt >= 30 {
            lastSaveAt = now
            save()
        }
    }

    /// Seconds listened to one item, across all days.
    func seconds(forItemId itemId: String) -> Int {
        data.secondsPerItem[itemId] ?? 0
    }

    /// Items by listening time, longest first. The honest "most listened",
    /// as opposed to "most often started".
    func topItems(limit: Int, matching isIncluded: (String) -> Bool = { _ in true }) -> [(id: String, seconds: Int)] {
        data.secondsPerItem
            .filter { isIncluded($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (id: $0.key, seconds: $0.value) }
    }

    /// Seconds per radio station, across all devices. The measure the
    /// "Most Played" row ranks by.
    func radioSeconds() -> [String: Int] {
        data.secondsPerItem.filter { ListeningClasses.isLive($0.key) }
    }

    /// The sync WITNESS for the diagnosis. One line per foreign
    /// device pot, so an iPad copy can answer "do the iPhone pots arrive?"
    /// without a Mac. Reads the already-fetched pots, changes nothing.
    func foreignPotOverview() -> [(device: String, daySeconds: Int, radioSeconds: Int)] {
        ListeningStatsSync.overview(pots: foreign, ownDeviceId: SyncHistoryStore.deviceId)
    }

    /// On pause/stop: persist the remaining seconds immediately, and let the
    /// other devices see them. A published pot that lags by a whole session
    /// would make the totals wrong on the iPad in exactly the way this design
    /// is supposed to prevent.
    func flush() {
        save()
        ListeningStatsCloudSync.shared.publish()
    }

    private func save() {
        // Compaction runs where the file is written, not on a timer: distant
        // days collapse into months, and the item pot keeps its top entries.
        // Both are named rules, not silent caps. The totals stay exact.
        ownData = ListeningStatsSync.compacted(ownData, todayKey: Self.dayKey(for: Date()))
        ownData.secondsPerItem = ListeningStatsSync.cappedItems(ownData.secondsPerItem,
                                                                limit: Self.itemPotCap)
        let snapshot = ownData
        let url = fileURL
        // detached because the write must finish even when the caller's task is cancelled
        Task.detached(priority: .utility) {
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
    }

    // MARK: - Queries

    func seconds(on date: Date) -> Int {
        data.secondsPerDay[Self.dayKey(for: date)] ?? 0
    }

    func totalSeconds() -> Int {
        data.secondsPerDay.values.reduce(0, +)
    }

    func seconds(lastDays days: Int) -> Int {
        dailySeconds(lastDays: days).reduce(0) { $0 + $1.seconds }
    }

    /// Oldest first. Ready to render as a bar row.
    func dailySeconds(lastDays days: Int) -> [(date: Date, seconds: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, seconds(on: day))
        }
    }

    /// Consecutive days with listening time, up to today (a listen-free today
    /// does not yet break the streak. Counting runs backwards from yesterday).
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
