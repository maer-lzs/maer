// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How listening statistics travel between a person's own devices.
///
/// **Every device writes ONLY its own pot, and summing happens on READ.**
/// That is not a style choice: a single shared counter loses time structurally.
/// Two devices read 100, both write 110, and the result is 110 instead of 120 —
/// for counters that is not repairable afterwards, only avoidable. With one pot
/// per device no write ever touches another device's value, so there is nothing
/// to race over, and the origin stays visible ("of which iPhone/iPad") without
/// anyone having to build that view today.
///
/// **What travels, and why not everything** (measured against the 1 MB budget
/// the channel shares with podcast progress and playlists): the day pot costs
/// ~1.9 % for five years on two devices, radio seconds ~6 % for 500 stations.
/// Seconds per podcast episode would cost 85 % on their own — and they are not
/// needed: everything that HAS a position already carries its listening time in
/// a channel that syncs. The line is "does it have a position", and only radio
/// falls on the other side.
nonisolated enum ListeningStatsSync {

    /// One device's key. The id is part of the key, never part of the value —
    /// that is what makes a foreign pot impossible to overwrite by accident.
    static let keyPrefix = "listeningStats."

    static func key(forDeviceId deviceId: String) -> String { keyPrefix + deviceId }

    static func deviceId(fromKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// What a device publishes: its days, and of its item seconds ONLY the ones
    /// no other channel already carries. Filtering here rather than at the call
    /// site keeps the budget decision in one place.
    static func publishable(_ data: ListeningStatsData) -> ListeningStatsData {
        ListeningStatsData(
            secondsPerDay: data.secondsPerDay,
            secondsPerItem: data.secondsPerItem.filter { ListeningClasses.isLive($0.key) })
    }

    /// The total across devices: this device's own numbers come from its LOCAL
    /// file (always the freshest), every other device from its published pot.
    ///
    /// The own pot in the cloud is deliberately ignored — it is a mirror of the
    /// local file, and adding both would count this device twice. That is the
    /// double-counting the whole per-device design exists to prevent, and it
    /// would be invisible: the number would just be too large.
    static func merged(local: ListeningStatsData,
                       ownDeviceId: String,
                       foreign: [String: ListeningStatsData]) -> ListeningStatsData {
        var days = local.secondsPerDay
        var items = local.secondsPerItem
        for (deviceId, pot) in foreign where deviceId != ownDeviceId {
            for (day, seconds) in pot.secondsPerDay { days[day, default: 0] += seconds }
            for (item, seconds) in pot.secondsPerItem { items[item, default: 0] += seconds }
        }
        return ListeningStatsData(secondsPerDay: days, secondsPerItem: items)
    }

    // MARK: - Verdichtung

    /// Days older than the horizon collapse into their month. A NAMED rule, not
    /// a silent cap: the total stays exact because the seconds are summed, not
    /// dropped — only the granularity of the distant past is given up, and no
    /// surface asks for a single day two years back.
    ///
    /// A month key is `yyyy-MM` and therefore shorter than a day key, so it can
    /// never collide with one.
    static let dayHorizon = 730

    static func compacted(_ data: ListeningStatsData, todayKey: String,
                          horizonDays: Int = dayHorizon) -> ListeningStatsData {
        guard let horizon = dayKey(todayKey, minusDays: horizonDays) else { return data }
        var days: [String: Int] = [:]
        for (key, seconds) in data.secondsPerDay {
            let target = key.count == 10 && key < horizon ? String(key.prefix(7)) : key
            days[target, default: 0] += seconds
        }
        return ListeningStatsData(secondsPerDay: days, secondsPerItem: data.secondsPerItem)
    }

    /// Pure date arithmetic on the stored key form, with the same fixed
    /// calendar the keys were written with — a device set to a non-Gregorian
    /// calendar must not compute a different horizon than the one that wrote
    /// them.
    static func dayKey(_ key: String, minusDays days: Int) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: key),
              let moved = calendar.date(byAdding: .day, value: -days, to: date)
        else { return nil }
        return formatter.string(from: moved)
    }

    /// The item pot keeps the top entries by seconds — same shape as the radio
    /// store's own cap, so a station heard a lot is never evicted for one heard
    /// once. Ties resolve by id so the result is stable across devices.
    static func cappedItems(_ items: [String: Int], limit: Int) -> [String: Int] {
        guard items.count > limit else { return items }
        let kept = items.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
