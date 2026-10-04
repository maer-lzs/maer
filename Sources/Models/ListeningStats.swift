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
    /// One table of the totals (day to seconds, item to seconds).
    typealias StatsTable = KeyedRowStore<Int>
    /// The two pots as rows (day to seconds, item to seconds).
    /// The one opening of the rows: every caller awaits the same task.
    private var rowsOpening: Task<(StatsTable, StatsTable)?, Never>?
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read. Advances only when a write landed; a start read
    /// that could not read every row leaves it unknown, and then no write
    /// removes a row nobody read.
    private var rowBase: RowBase<ListeningStatsData> = .fresh
    private var pendingWrite: Task<Void, Never>?
    /// The own pot taken back over rows nobody could read: it counts in
    /// what is shown and published; when the rows are read it is the part
    /// of the stock that is NOT this run's counting (`rowsReadForWrite`).
    private var potHeld: ListeningStatsData?

    /// The database the rows live in; a witness hands in a file of its own.
    private let database: MaerDatabase
    /// Which table the start could not read at all. While one is unread no
    /// write goes: its rows may hold more than anything this run knows, and
    /// a write replaces a row's value whole (`rowsReadForWrite`).
    private var unreadDays = false
    private var unreadItems = false

    /// The carrier is chosen at start-up and again when the access changes
    /// (`follow`); a witness hands in a recording one.
    convenience init(carrier: any StatsCarrier = StatsCarriers.make(), database: MaerDatabase = .shared) {
        self.init(carrier: carrier, database: database, startReadFails: false)
    }

    private init(carrier: any StatsCarrier, database: MaerDatabase, startReadFails: Bool) {
        self.carrier = carrier
        self.database = database
        // Rows first, synchronously through a reader (the init is
        // synchronous by contract: the first tick must find its pot).
        let started = Date()
        let (days, items) = startReadFails ? (nil, nil) : Self.readTables(database)
        let (loaded, base) = Self.startBase(days: days, items: items)
        let stock = loaded ?? ListeningStatsData()
        ownData = stock
        data = stock
        rowBase = base
        unreadDays = days == nil
        unreadItems = items == nil
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Logger.library.notice("STATS start: days=\(stock.secondsPerDay.count) items=\(stock.secondsPerItem.count) ms=\(ms)")
    }

    #if DEBUG
    /// Test seam: a start whose read of both tables failed, over a database
    /// whose rows a later read finds.
    static func testFailingStart(carrier: any StatsCarrier, database: MaerDatabase) -> ListeningStatsStore {
        ListeningStatsStore(carrier: carrier, database: database, startReadFails: true)
    }
    #endif

    /// Both tables, each read on its own: a table that cannot be read leaves
    /// the other one's rows standing (nil = could not be read).
    private static func readTables(_ database: MaerDatabase) -> (days: StatsTable.Load?, items: StatsTable.Load?) {
        var days, items: StatsTable.Load?
        do {
            if let reader = try database.readerNow() {
                do {
                    days = try StatsTable.loadNow(table: .statsDay, reader: reader)
                } catch {
                    Logger.library.error("STATS rows read failed table=days reason=\(String(describing: error), privacy: .public) base=unknown")
                }
                do {
                    items = try StatsTable.loadNow(table: .statsItem, reader: reader)
                } catch {
                    Logger.library.error("STATS rows read failed table=items reason=\(String(describing: error), privacy: .public) base=unknown")
                }
            } else {
                // No file yet is a fresh install: nothing to read.
                days = StatsTable.Load(rows: [:], skipped: 0)
                items = StatsTable.Load(rows: [:], skipped: 0)
            }
        } catch {
            Logger.library.error("STATS rows read failed reason=\(String(describing: error), privacy: .public) base=unknown")
        }
        return (days, items)
    }

    /// The stock and the base the start leaves, from the two tables read on
    /// their own (nil = the table could not be read). A table that could
    /// not be read makes the rows unknown, and the store starts with what
    /// the other one held, which is also what a write may remove; rows that
    /// did not decode make them unknown with what did; nothing read and
    /// nothing skipped is fresh.
    nonisolated static func startBase(days: StatsTable.Load?, items: StatsTable.Load?)
    -> (stock: ListeningStatsData?, base: RowBase<ListeningStatsData>) {
        let stock = ListeningStatsData(secondsPerDay: days?.rows ?? [:], secondsPerItem: items?.rows ?? [:])
        let read = !stock.secondsPerDay.isEmpty || !stock.secondsPerItem.isEmpty
        guard let days, let items else {
            return (read ? stock : nil, .unknown(seen: read ? stock : nil))
        }
        let skipped = days.skipped + items.skipped
        guard read || skipped > 0 else { return (nil, .fresh) }
        return (stock, RowBase.afterLoad(rows: stock, skipped: skipped))
    }

    private func openRows() async -> (StatsTable, StatsTable)? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<(StatsTable, StatsTable)?, Never> {
            do {
                let connection = try self.database.connection()
                let days = try await StatsTable(connection: connection, table: .statsDay)
                let items = try await StatsTable(connection: connection, table: .statsItem)
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
    /// The other direction is the one that needs care: a device whose rows
    /// could not be read at all (a fresh file after a reset, a read that
    /// failed as a whole) but whose pot still stands in iCloud merges its own
    /// numbers back instead of starting at zero (`adoptedOwnPot`). A table
    /// that was read is never replaced by the pot, which is only a part of
    /// it; a second run changes nothing because the rows are then known.
    /// Only a fresh file takes the pot as a write; over rows that could not
    /// be read the pot is shown and published, and nothing is written until
    /// the rows are read (`rowsReadForWrite`), since they may hold more.
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
        adoptOwnPot(carrier.pots()[SyncHistoryStore.deviceId])
        publish()
        cloudChanged()
    }

    /// This device's own published pot back into the stock when the rows
    /// could not be read (`ListeningStatsSync.adoptedOwnPot`): written after
    /// a fresh start; over unread rows only shown and published, and held
    /// apart, so the read that comes later can tell the pot from what this
    /// run counted (`rowsReadForWrite`).
    private func adoptOwnPot(_ ownPot: ListeningStatsData?) {
        if let adopted = ListeningStatsSync.adoptedOwnPot(base: rowBase, own: ownData, pot: ownPot) {
            let writes = ListeningStatsSync.adoptionWrites(rowBase)
            Logger.library.notice("listening stats: local rows not read (plan=\(String(describing: self.rowBase.plan), privacy: .public)), merging this device's own published pot (days=\(ownPot?.secondsPerDay.count ?? 0) items=\(ownPot?.secondsPerItem.count ?? 0)) \(writes ? "written" : "held until the rows are read", privacy: .public)")
            if writes {
                ownData = adopted
                save()
            } else {
                let added = ListeningStatsSync.above(ownData, in: adopted)
                let held = potHeld ?? ListeningStatsData()
                potHeld = ListeningStatsData(
                    secondsPerDay: held.secondsPerDay.merging(added.secondsPerDay, uniquingKeysWith: +),
                    secondsPerItem: held.secondsPerItem.merging(added.secondsPerItem, uniquingKeysWith: +))
                ownData = adopted
            }
        }
    }

    /// Whether a write may go. Yes when every table was read, at the start
    /// or here. A table the start could not read is read again; while it
    /// still cannot be read nothing is written, because a write replaces a
    /// row's value whole and nobody knows what the unread row holds. Once
    /// it is read, each such table is rebuilt from its rows plus what this
    /// run counted above the held pot (`ListeningStatsSync.rebuilt`), and
    /// the rows are known.
    private func rowsReadForWrite() -> Bool {
        guard unreadDays || unreadItems else { return true }
        let (days, items) = Self.readTables(database)
        guard let days, let items else {
            Logger.library.notice("STATS save held: rows still not read days=\(days != nil) items=\(items != nil)")
            return false
        }
        ownData = ListeningStatsSync.rebuilt(own: ownData, held: potHeld,
                                             readDays: unreadDays ? days.rows : nil,
                                             readItems: unreadItems ? items.rows : nil)
        rowBase = Self.startBase(days: days, items: items).base
        Logger.library.notice("STATS rows read on save: days=\(days.rows.count) items=\(items.rows.count) plan=\(String(describing: self.rowBase.plan), privacy: .public)")
        potHeld = nil
        unreadDays = false
        unreadItems = false
        recompose()
        return true
    }

    /// The carrier the access of this moment asks for, when it travels
    /// another way than the held one; see `PodcastCloudSync.follow`.
    func follow(_ next: @autoclosure () -> any StatsCarrier, signedIn: Bool, identityChanged: Bool = false, by caller: String) {
        guard CarrierWay.mustChange(holdsService: CarrierWay.isService(carrierName: carrier.name),
                                    signedIn: signedIn, identityChanged: identityChanged) else { return }
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

    /// This device's seconds per title in the form the server answers to
    /// (`NavidromeRekey.summed`); returns how many keys changed. The days
    /// stay as they are, they name no title.
    @discardableResult
    func rekeyItems(_ map: (String) -> String) -> Int {
        let changed = NavidromeRekey.changedCount(ownData.secondsPerItem.keys, map)
        guard changed > 0 else { return 0 }
        ownData.secondsPerItem = NavidromeRekey.summed(ownData.secondsPerItem, map)
        // The held part moves with the keys, or the read that comes later
        // would count the pot as this run's listening under the new key.
        if let held = potHeld {
            potHeld = ListeningStatsData(secondsPerDay: held.secondsPerDay,
                                         secondsPerItem: NavidromeRekey.summed(held.secondsPerItem, map))
        }
        recompose()
        save()
        return changed
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
        // folded by an earlier build stay in the pot as they are; a month
        // key is shorter than a day key and never collides with one.
        // Only the pots' entries that changed go to the rows, in order. A
        // failure is logged; the totals live on in memory and the next
        // throttled save writes again.
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            // Over a table nobody could read nothing is written; the stock
            // is taken after a read that may have rebuilt it.
            guard let self, self.rowsReadForWrite() else { return }
            let snapshot = self.ownData
            guard let (days, items) = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or failed.
            let base = self.rowBase
            let dayBase = base.map(\.secondsPerDay)
            let itemBase = base.map(\.secondsPerItem)
            // The totals only grow or change their keys, never empty: an
            // empty table here is never what a write means.
            if dayBase.refuses(snapshot.secondsPerDay, .refused) || itemBase.refuses(snapshot.secondsPerItem, .refused) {
                Logger.library.error("STATS wipe REFUSED: empty table over days=\(dayBase.removable?.count ?? 0) items=\(itemBase.removable?.count ?? 0) plan=\(String(describing: base.plan), privacy: .public)")
                return
            }
            do {
                let d = try await days.apply(previous: dayBase.previous(for: snapshot.secondsPerDay), current: snapshot.secondsPerDay)
                let i = try await items.apply(previous: itemBase.previous(for: snapshot.secondsPerItem), current: snapshot.secondsPerItem)
                if base.plan != .diff || d.upserted + d.removed + i.upserted + i.removed > 0 {
                    Logger.library.notice("STATS save: days=\(d.upserted)/-\(d.removed) items=\(i.upserted)/-\(i.removed) plan=\(String(describing: base.plan), privacy: .public)")
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

    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        follow(StatsCarriers.make(), signedIn: signedIn, identityChanged: identityChanged, by: caller)
    }
}
