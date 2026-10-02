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
    static let shared = AccessFollowers.enrolled(ListeningStatsStore())

    /// THIS device's numbers. The file on disk. Every question about totals
    /// goes through `data` below, which adds the other devices.
    @Published private(set) var ownData: ListeningStatsData

    /// What the surfaces read: this device plus every other device's published
    /// pot. Summed on READ, never on write.
    private(set) var data: ListeningStatsData

    /// Other devices' pots as last seen. Refreshed when the carrier reports
    /// a change; kept as a value so a read never touches the store.
    private var foreign: [String: ListeningStatsData] = [:]

    /// The transport of the pots. The store reads and publishes through it
    /// and does not know where the pots travel; the carrier's ceiling
    /// shapes only what is published (`ListeningStatsSync.publishable`),
    /// never the file.
    private var carrier: any StatsCarrier
    private var generation = CarrierGeneration()

    private var lastSaveAt: TimeInterval = 0
    /// The seam to disk (Documents, one document).
    private let ablage = Ablage.documents
    private let documentName = "listening_stats.json"

    /// The two pots as rows (day to seconds, item to seconds). The document
    /// is read only when the rows hold nothing, and then poured into them
    /// once.
    /// The one opening of the rows: every caller awaits the same task.
    private var rowsOpening: Task<(KeyedRowStore<Int>, KeyedRowStore<Int>)?, Never>?
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read. Advances only when a write landed; a failed start
    /// read leaves it unknown, and then no write replaces the rows whole.
    private var rowBase: RowBase<ListeningStatsData> = .fresh
    private var pendingWrite: Task<Void, Never>?

    /// The carrier is chosen at start-up and again when the access changes
    /// (`follow`); a witness hands in a recording one.
    init(carrier: any StatsCarrier = StatsCarriers.make()) {
        self.carrier = carrier
        // Rows first, synchronously through a reader (the init is
        // synchronous by contract: the first tick must find its pot).
        let started = Date()
        var loaded: ListeningStatsData?
        var base: RowBase<ListeningStatsData> = .fresh
        var rowsFailed = false
        do {
            // No file yet is a fresh install: nothing to read, fresh base.
            let reader = try MaerDatabase.shared.readerNow()
            let days = try reader.map { try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: $0) }
                ?? KeyedRowStore<Int>.Load(rows: [:], skipped: 0)
            let items = try reader.map { try KeyedRowStore<Int>.loadNow(table: .statsItem, reader: $0) }
                ?? KeyedRowStore<Int>.Load(rows: [:], skipped: 0)
            let skipped = days.skipped + items.skipped
            if !days.rows.isEmpty || !items.rows.isEmpty || skipped > 0 {
                let stock = ListeningStatsData(secondsPerDay: days.rows, secondsPerItem: items.rows)
                loaded = stock
                // Rows that did not decode make the rows unknown, never
                // fresh; no document is poured over them.
                base = RowBase.afterLoad(rows: stock, skipped: skipped)
            }
        } catch {
            // The rows could not be READ (not: hold nothing): unknown, and
            // this run reads the document that was set aside, once.
            base = .unknown
            rowsFailed = true
            Logger.library.error("STATS rows read failed reason=\(String(describing: error), privacy: .public) fallback=migrated")
        }
        var migrate = false
        if loaded == nil {
            // The document: corrupt is kept aside by the seam and never
            // buried by an empty save; a missing file starts fresh.
            loaded = ablage.loadNow(ListeningStatsData.self, name: documentName).value
            if rowsFailed {
                loaded = loaded ?? ablage.loadNow(ListeningStatsData.self, name: documentName + ".migrated").value
            } else {
                migrate = loaded != nil
            }
        }
        let stock = loaded ?? ListeningStatsData()
        ownData = stock
        data = stock
        rowBase = base
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Logger.library.notice("STATS start: days=\(stock.secondsPerDay.count) items=\(stock.secondsPerItem.count) ms=\(ms)")
        if migrate {
            let name = documentName
            pendingWrite = Task { [weak self] in
                guard let self, let (days, items) = await self.openRows() else { return }
                do {
                    let writtenDays = try await days.replaceAll(stock.secondsPerDay)
                    let writtenItems = try await items.replaceAll(stock.secondsPerItem)
                    let document = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(name)
                    try DocumentMigration.setAside(document)
                    self.rowBase = .known(stock)
                    Logger.library.notice("STATS migrate: days=\(writtenDays) items=\(writtenItems)")
                } catch {
                    Logger.library.error("STATS migrate failed reason=\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func openRows() async -> (KeyedRowStore<Int>, KeyedRowStore<Int>)? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<(KeyedRowStore<Int>, KeyedRowStore<Int>)?, Never> {
            do {
                let connection = try MaerDatabase.shared.connection()
                let days = try await KeyedRowStore<Int>(connection: connection, table: .statsDay)
                let items = try await KeyedRowStore<Int>(connection: connection, table: .statsItem)
                return (days, items)
            } catch {
                Logger.library.error("STATS rows open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }

    /// The last handed-over write (tests).
    func awaitPendingWrites() async {
        await pendingWrite?.value
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
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        guard !didStart else { publish(); cloudChanged(); return }
        didStart = true
        startCarrier(by: "start")
    }

    /// The start of a carrier, at the cold start and when the store takes
    /// another carrier while it runs: the same steps both times.
    private func startCarrier(by caller: String) {
        Logger.library.notice("STATS carrier=\(self.carrier.name, privacy: .public) by=\(caller, privacy: .public)")
        carrier.start(onChange: generation.guarded({ [weak self] in self?.generation }) { [weak self] in
            self?.cloudChanged()
        })
        let ownPot = carrier.pots()[SyncHistoryStore.deviceId]
        if ownData.secondsPerDay.isEmpty, let ownPot, !ownPot.secondsPerDay.isEmpty {
            Logger.library.notice("listening stats: local file empty, adopting this device's own published pot (\(ownPot.secondsPerDay.count) days)")
            ownData = ownPot
            save()
        }
        publish()
        cloudChanged()
    }

    /// The carrier the access of this moment asks for, when it travels
    /// another way than the held one; see `PodcastCloudSync.follow`.
    func follow(_ next: @autoclosure () -> any StatsCarrier, signedIn: Bool, by caller: String) {
        guard CarrierWay.mustChange(holdsService: CarrierWay.isService(carrierName: carrier.name),
                                    signedIn: signedIn) else { return }
        carrier.stop()
        CarrierRefreshers.unregister(carrier)
        carrier = next()
        generation.advance()
        guard didStart else { return }
        startCarrier(by: caller)
    }

    /// Guard against double delivery registration: `start()` runs again when
    /// the switch is flipped on, and a second observer would double every
    /// recompose.
    private var didStart = false

    /// Re-read the other devices and recompose the totals.
    func cloudChanged() {
        foreign = carrier.pots()
        recompose()
    }

    /// This device's pot to the carrier, as it stands right now. On a
    /// carrier with a ceiling only the live items travel, capped
    /// (everything that has a position already carries its time in a
    /// channel that syncs); on a carrier with room the whole pot does.
    private func publish() {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        let pot = carrier.hasRoomLimit
            ? ListeningStatsSync.publishable(ownData, itemCap: ListeningStatsSync.itemPotCap)
            : ownData
        carrier.publish(pot, deviceId: SyncHistoryStore.deviceId, by: "stats")
    }

    private func recompose() {
        let signpost = PerfSignpost.statsMerge()
        defer { signpost.end() }
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
    /// as opposed to "most often started". `atLeast` keeps out what was
    /// barely heard, before the limit, so it takes no place.
    func topItems(limit: Int, atLeast: Int = 0,
                  matching isIncluded: (String) -> Bool = { _ in true }) -> [(id: String, seconds: Int)] {
        data.secondsPerItem
            .filter { $0.value >= atLeast && isIncluded($0.key) }
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
        publish()
    }

    private func save() {
        // The file takes the pot whole. The item cap belongs to publishing
        // (`ListeningStatsSync.publishable`), because a carrier's ceiling
        // can appear mid-session and a cut here would make it permanent.
        // The days are never folded any more: a day costs about five
        // bytes, and the reason for folding was the ceiling. Months already
        // folded by an earlier build stay readable as they are
        // (`ListeningStatsSync.compacted` remains as the rule for them).
        // Only the pots' entries that changed go to the rows, in order. A
        // failure is logged; the totals live on in memory and the next
        // throttled save writes again.
        let snapshot = ownData
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, let (days, items) = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or failed.
            let base = self.rowBase
            do {
                switch base.plan {
                case .diff:
                    let before = base.knownValue ?? ListeningStatsData()
                    let d = try await days.apply(previous: before.secondsPerDay, current: snapshot.secondsPerDay)
                    let i = try await items.apply(previous: before.secondsPerItem, current: snapshot.secondsPerItem)
                    if d.upserted + d.removed + i.upserted + i.removed > 0 {
                        Logger.library.notice("STATS save: days=\(d.upserted)/-\(d.removed) items=\(i.upserted)/-\(i.removed)")
                    }
                case .upsertOnly:
                    let d = try await days.apply(previous: [:], current: snapshot.secondsPerDay)
                    let i = try await items.apply(previous: [:], current: snapshot.secondsPerItem)
                    Logger.library.notice("STATS save: upsertOnly days=\(d.upserted) items=\(i.upserted)")
                }
                self.rowBase = .known(snapshot)
            } catch {
                Logger.library.error("STATS save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
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

extension ListeningStatsStore: AccessFollower {
    var followerName: String { "stats" }

    func followAccess(signedIn: Bool, by caller: String) {
        follow(StatsCarriers.make(), signedIn: signedIn, by: caller)
    }
}
