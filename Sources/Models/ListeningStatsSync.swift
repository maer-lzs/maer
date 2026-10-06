// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How listening statistics travel between a person's own devices.
///
/// **Every device writes ONLY its own pot, and summing happens on READ.**
/// That is not a style choice: a single shared counter loses time structurally.
/// Two devices read 100, both write 110, and the result is 110 instead of 120.
/// For counters that is not repairable afterwards, only avoidable. With one pot
/// per device no write ever touches another device's value, so there is nothing
/// to race over, and the origin stays visible ("of which iPhone/iPad") without
/// anyone having to build that view today.
///
/// **What travels, and why not everything** (measured against the 1 MB budget
/// the channel shares with podcast progress and playlists): the day pot costs
/// ~1.9 % for five years on two devices, radio seconds ~6 % for 500 stations.
/// Seconds per podcast episode would cost 85 % on their own. And they are not
/// needed: everything that HAS a position already carries its listening time in
/// a channel that syncs. The line is "does it have a position", and only radio
/// falls on the other side.
nonisolated enum ListeningStatsSync {

    /// One device's key. The id is part of the key, never part of the value.
    /// That is what makes a foreign pot impossible to overwrite by accident.
    static let keyPrefix = "listeningStats."

    static func key(forDeviceId deviceId: String) -> String { keyPrefix + deviceId }

    static func deviceId(fromKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// How many items travel ON A CARRIER WITH A CEILING. 500 radio
    /// stations cost ~6 % of the shared iCloud megabyte; the cap is what
    /// keeps that a ceiling instead of a hope. The ceiling decides what
    /// TRAVELS, never what stays: the local pot is written whole, because
    /// the carrier's answer can flip within a session (the account goes
    /// away, the cloud carrier falls back) and a cut at the file would
    /// throw seconds away for good that no other channel holds.
    static let itemPotCap = 500

    /// The account's own totals on this device (the ledger of
    /// `ListeningStatsStore`): what it brought along when it took the device
    /// over (`carried`, its rest), plus what the device counted since
    /// (`device` minus `since`, the device's totals at the takeover). The
    /// device's rows only grow, so nothing is removed at a change of
    /// account; per key never below zero.
    static func owned(device: ListeningStatsData, carried: ListeningStatsData,
                      since: ListeningStatsData) -> ListeningStatsData {
        func part(_ device: [String: Int], _ carried: [String: Int], _ since: [String: Int]) -> [String: Int] {
            var out = carried
            for (key, value) in device {
                let grown = value - (since[key] ?? 0)
                if grown > 0 { out[key, default: 0] += grown }
            }
            return out
        }
        return ListeningStatsData(
            secondsPerDay: part(device.secondsPerDay, carried.secondsPerDay, since.secondsPerDay),
            secondsPerItem: part(device.secondsPerItem, carried.secondsPerItem, since.secondsPerItem))
    }

    /// The way back from `owned`: an account's published totals in the
    /// space of the device's rows, so a pot taken back after a reset of the
    /// rows counts neither the carried part twice nor what the device had
    /// before the takeover too little. Per key the device's totals at the
    /// takeover (`since`) plus what the pot holds above the carried part.
    static func deviceSpace(pot: ListeningStatsData, carried: ListeningStatsData,
                            since: ListeningStatsData) -> ListeningStatsData {
        func part(_ pot: [String: Int], _ carried: [String: Int], _ since: [String: Int]) -> [String: Int] {
            var out = since
            for (key, value) in pot {
                let grown = value - (carried[key] ?? 0)
                if grown > 0 { out[key, default: 0] += grown }
            }
            return out
        }
        return ListeningStatsData(
            secondsPerDay: part(pot.secondsPerDay, carried.secondsPerDay, since.secondsPerDay),
            secondsPerItem: part(pot.secondsPerItem, carried.secondsPerItem, since.secondsPerItem))
    }

    /// What a device publishes: its days, and of its item seconds ONLY the ones
    /// no other channel already carries, capped to `itemCap` when the carrier
    /// has a ceiling. Filtering and capping here rather than at the call site
    /// keeps the budget decision in one place.
    static func publishable(_ data: ListeningStatsData, itemCap: Int? = nil) -> ListeningStatsData {
        let live = data.secondsPerItem.filter { ListeningClasses.isLive($0.key) }
        return ListeningStatsData(
            secondsPerDay: data.secondsPerDay,
            secondsPerItem: itemCap.map { cappedItems(live, limit: $0) } ?? live)
    }

    /// Whether a start takes this device's own published pot back, and the
    /// stock it then holds; nil = nothing to adopt. Only when the start
    /// could not read the local rows at all (a fresh file, or a read that
    /// failed as a whole): a table that was read, empty or not, is the local
    /// truth, and a pot taken over it would remove read rows on the next
    /// write. The pot is a part by construction (`publishable`: live items
    /// only, capped), so it is merged into what the device holds, per key the
    /// larger value, never written as the whole stock.
    static func adoptedOwnPot(base: RowBase<ListeningStatsData>, own: ListeningStatsData,
                              pot: ListeningStatsData?) -> ListeningStatsData? {
        switch base {
        case .fresh, .unknown(seen: nil): break
        case .known, .unknown: return nil
        }
        guard let pot, !pot.secondsPerDay.isEmpty || !pot.secondsPerItem.isEmpty else { return nil }
        let merged = ListeningStatsData(
            secondsPerDay: own.secondsPerDay.merging(pot.secondsPerDay, uniquingKeysWith: max),
            secondsPerItem: own.secondsPerItem.merging(pot.secondsPerItem, uniquingKeysWith: max))
        return merged == own ? nil : merged
    }

    /// Whether the start may WRITE an adopted pot. After a fresh start yes:
    /// the table was read and is empty, nothing on disk is covered. While
    /// the rows could not be read no: they still stand on disk and may hold
    /// more than the pot, which lags them by every save since the last
    /// publish. Then the pot is only shown and published, and the store
    /// writes nothing until the rows are read (`rebuilt`).
    static func adoptionWrites(_ base: RowBase<ListeningStatsData>) -> Bool {
        if case .fresh = base { return true }
        return false
    }

    /// The stock once a table the start could not read has been read: per
    /// such table its rows, plus what this run counted (the stock above the
    /// held pot), per key the sum; a table that was read at the start
    /// (`nil` here) keeps the stock as it is. The pot lags the rows, so it
    /// is left out; the rows already hold what it held.
    static func rebuilt(own: ListeningStatsData, held: ListeningStatsData?,
                        readDays: [String: Int]?, readItems: [String: Int]?) -> ListeningStatsData {
        let counted = above(held ?? ListeningStatsData(), in: own)
        return ListeningStatsData(
            secondsPerDay: readDays.map { $0.merging(counted.secondsPerDay, uniquingKeysWith: +) } ?? own.secondsPerDay,
            secondsPerItem: readItems.map { $0.merging(counted.secondsPerItem, uniquingKeysWith: +) } ?? own.secondsPerItem)
    }

    /// Per key what `stock` holds above `held`; keys at or below it are left
    /// out. What this run counted on top of an adopted pot, and the part an
    /// adoption adds to what is held.
    static func above(_ held: ListeningStatsData, in stock: ListeningStatsData) -> ListeningStatsData {
        func rest(_ values: [String: Int], _ floor: [String: Int]) -> [String: Int] {
            values.reduce(into: [:]) { out, entry in
                let left = entry.value - (floor[entry.key] ?? 0)
                if left > 0 { out[entry.key] = left }
            }
        }
        return ListeningStatsData(secondsPerDay: rest(stock.secondsPerDay, held.secondsPerDay),
                                  secondsPerItem: rest(stock.secondsPerItem, held.secondsPerItem))
    }

    /// The total across devices: this device's own numbers come from its LOCAL
    /// file (always the freshest), every other device from its published pot.
    ///
    /// The own pot in the cloud is deliberately ignored. It is a mirror of the
    /// local file, and adding both would count this device twice. That is the
    /// double-counting the whole per-device design exists to prevent, and it
    /// would be invisible: the number would just be too large.
    /// The diagnosis line's pot list. The pots dictionary holds ALL cloud
    /// pots INCLUDING the own mirror (the merge rule skips it). This list
    /// must skip it too, or every device reports itself as a foreign pot
    /// (measured on both devices: "fremde Töpfe: 2" with two devices).
    static func overview(pots: [String: ListeningStatsData], ownDeviceId: String)
        -> [(device: String, daySeconds: Int, radioSeconds: Int)] {
        pots.filter { $0.key != ownDeviceId }.map { entry in
            (device: entry.key,
             daySeconds: entry.value.secondsPerDay.values.reduce(0, +),
             radioSeconds: entry.value.secondsPerItem
                 .filter { ListeningClasses.isLive($0.key) }.values.reduce(0, +))
        }
        .sorted { $0.device < $1.device }
    }

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

    /// The item pot keeps the top entries by seconds. Same shape as the radio
    /// store's own cap, so a station heard a lot is never evicted for one heard
    /// once. Ties resolve by id so the result is stable across devices.
    static func cappedItems(_ items: [String: Int], limit: Int) -> [String: Int] {
        guard items.count > limit else { return items }
        let kept = items.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
