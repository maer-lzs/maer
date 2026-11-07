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

/// The device id the statistics write under, and the step when another
/// device writes under it: the app's answer from the sync history's holder
/// (`StatsDeviceIds.live`), a witness's of its own.
@MainActor
struct StatsDeviceIds {
    /// The lasting device id, nil while the keychain does not give it out.
    var lasting: () -> String?
    /// Gives the shared id up; false when the fresh one was not saved.
    var leave: () -> Bool
}

/// Records listening time (1-second ticks from the player time observer) and
/// answers the stats page's questions. Disk writes throttled and in the
/// background. Ticking must cost nothing.
@MainActor
final class ListeningStatsStore: ObservableObject {
    static let shared = AccessFollowers.enrolled(ListeningStatsStore(
        identity: { AccessFollowers.identity }, shelf: MaerDatabase.restingShelf))

    /// THIS device's numbers. The file on disk. Every question about totals
    /// goes through `data` below, which adds the other devices.
    @Published private(set) var ownData: ListeningStatsData

    /// What the surfaces read: this device plus every other device's published
    /// pot. Summed on READ, never on write: a change only drops the sum, and
    /// the next read merges again. The tick adds a second every second;
    /// merging every pot on each of them, read or not, was the work.
    var data: ListeningStatsData {
        if let composed { return composed }
        let merged = compose()
        composed = merged
        return merged
    }
    private var composed: ListeningStatsData?

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
    /// Whether the start missed rows: a table it could not read, or rows that
    /// did not decode in this build. A write does not clear it, only a read
    /// of both tables that sees every row (the move names it, `rekeyItems`).
    private(set) var startMissedRows = false
    /// The two tables as one read leaves them (nil = could not be read).
    typealias Loads = (days: StatsTable.Load?, items: StatsTable.Load?)
    /// What the start read of each table found, kept while another table is
    /// unread: a table the start read is not read again, since nothing is
    /// written while one is unread and its rows are what the start found.
    private var readAtStart: Loads = (nil, nil)
    /// The read again that runs, so a second caller awaits it.
    private var rereading: Task<Loads, Never>?
    /// Whether a write is held because a table stays unread: this run's
    /// listening is then in memory only, and gone when the process ends. The
    /// statistics page says so while it holds.
    @Published private(set) var rowsHeld = false
    /// The sync history, where the person reads that a write is held; one
    /// entry per run (`heldNoted`).
    private let history: any SyncHistoryStoring
    private var heldNoted = false

    /// The carrier is chosen at start-up and again when the access changes
    /// (`follow`); a witness hands in a recording one, and a short
    /// `firstStandLimit` for a carrier that never delivers, and the device
    /// ids (`StatsDeviceIds`).
    convenience init(carrier: any StatsCarrier = StatsCarriers.make(), database: MaerDatabase = .shared,
                     history: any SyncHistoryStoring = SyncHistoryStore.shared,
                     identity: @escaping () -> String? = { nil }, shelf: RestingShelf? = nil,
                     firstStandLimit: Duration = ListeningStatsStore.firstStandLimit,
                     deviceIds: StatsDeviceIds = .live) {
        self.init(carrier: carrier, database: database, history: history, startReadFails: false,
                  identity: identity, shelf: shelf, firstStandLimit: firstStandLimit, deviceIds: deviceIds)
    }

    private init(carrier: any StatsCarrier, database: MaerDatabase, history: any SyncHistoryStoring, startReadFails: Bool,
                 identity: @escaping () -> String? = { nil }, shelf: RestingShelf? = nil,
                 firstStandLimit: Duration = ListeningStatsStore.firstStandLimit,
                 deviceIds: StatsDeviceIds = .live) {
        self.carrier = carrier
        self.database = database
        self.history = history
        self.identity = identity
        self.shelf = shelf
        self.firstStandWait = firstStandLimit
        self.deviceIds = deviceIds
        // The ledger is the shelf's; an unreadable one holds every hand-over
        // and publish, since without it the device's whole history would
        // count as the account's.
        var loadedLedger = Ledger()
        var ledgerFailed = false
        do {
            loadedLedger = try shelf?.rest(Ledger.self, of: Self.ledgerFamily, owner: Self.ledgerOwner) ?? Ledger()
        } catch {
            ledgerFailed = true
            ledgerUnread = true
            Logger.library.error("STATS ledger unreadable reason=\(String(describing: error), privacy: .public)")
        }
        ledger = loadedLedger
        // Rows first, synchronously through a reader (the init is
        // synchronous by contract: the first tick must find its pot).
        let started = Date()
        let (days, items) = startReadFails ? (nil, nil) : Self.readTables(database)
        let (loaded, base) = Self.startBase(days: days, items: items)
        let stock = loaded ?? ListeningStatsData()
        ownData = stock
        // What is shown is the holding account's part from the first read,
        // by the rule of `ownerPot`: nothing of this device's while the
        // ledger is unread.
        composed = Self.ownerPot(device: stock, ledger: loadedLedger, unread: ledgerFailed)
        rowBase = base
        if case .unknown = base { startMissedRows = true } else { startMissedRows = false }
        unreadDays = days == nil
        unreadItems = items == nil
        if unreadDays || unreadItems { readAtStart = (days, items) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // The base and its plan: rows that did not decode leave the base
        // unknown, as a later read line says too; the plan alone reads the
        // same for a fresh table and one nobody could read.
        Logger.library.notice("STATS start: days=\(stock.secondsPerDay.count) items=\(stock.secondsPerItem.count) base=\(base.basis, privacy: .public) plan=\(String(describing: base.plan), privacy: .public) ms=\(ms)")
        // The totals keep a chain of their own (their rule, `save`); the
        // app's two ends wait for it with every row chain.
        RowKeepers.register(owner: self) { [weak self] in await self?.awaitPendingWrites() }
    }

    #if DEBUG
    /// Test seam: a start whose read of both tables failed, over a database
    /// whose rows a later read finds.
    static func testFailingStart(carrier: any StatsCarrier, database: MaerDatabase,
                                 history: any SyncHistoryStoring) -> ListeningStatsStore {
        ListeningStatsStore(carrier: carrier, database: database, history: history, startReadFails: true)
    }
    #endif

    /// The asked tables, each read on its own: a table that cannot be read
    /// leaves the other one's rows standing (nil = could not be read or
    /// not asked). Synchronous and off any actor, for the start and for the
    /// read again off the main actor.
    nonisolated private static func readTables(_ database: MaerDatabase,
                                               days readDays: Bool = true, items readItems: Bool = true) -> Loads {
        var days, items: StatsTable.Load?
        do {
            if let reader = try database.readerNow() {
                if readDays {
                    do {
                        days = try StatsTable.loadNow(table: .statsDay, reader: reader)
                    } catch {
                        Logger.library.error("STATS rows read failed table=days reason=\(String(describing: error), privacy: .public) base=unknown")
                    }
                }
                if readItems {
                    do {
                        items = try StatsTable.loadNow(table: .statsItem, reader: reader)
                    } catch {
                        Logger.library.error("STATS rows read failed table=items reason=\(String(describing: error), privacy: .public) base=unknown")
                    }
                }
            } else {
                // No file yet is a fresh install: nothing to read.
                if readDays { days = StatsTable.Load(rows: [:], skipped: 0) }
                if readItems { items = StatsTable.Load(rows: [:], skipped: 0) }
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

    /// The last handed-over write (tests, the app's two ends).
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
        // The lasting device id arriving in this process: the own pot from
        // before stops counting as foreign, and a held publish may go.
        NotificationCenter.default.addObserver(forName: SyncHistoryStore.deviceIdArrived, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudChanged() }
        }
        startCarrier(by: "start")
    }

    /// The start of a carrier, at the cold start and when the store takes
    /// another carrier while it runs: the same steps both times. A start
    /// without the lasting device id holds like a start without rows, so
    /// nothing is taken back or published under an id for this process.
    private func startCarrier(by caller: String) {
        Logger.library.notice("STATS carrier=\(self.carrier.name, privacy: .public) by=\(caller, privacy: .public)")
        carrier.start(onChange: generation.guarded({ [weak self] in self?.generation }) { [weak self] in
            self?.cloudChanged()
        })
        if ListeningStatsSync.waitsForFirstStand(takesBack: ListeningStatsSync.takesOwnPotBack(rowBase),
                                                 delivered: carrier.hasDeliveredFirst)
            || lastingDeviceId() == nil {
            holdForFirstStand()
        } else {
            adoptOwnPot(asFreshStart: false)
        }
        publish()
        cloudChanged()
    }

    /// The lasting device id and the step when another device writes
    /// under it.
    private let deviceIds: StatsDeviceIds
    /// The lasting device id, nil while the keychain does not give it out.
    private func lastingDeviceId() -> String? { deviceIds.lasting() }
    /// The id that tells own pots from foreign ones: the lasting one, before
    /// it an id for this process.
    private var ownDeviceId: String { lastingDeviceId() ?? SyncHistoryStore.deviceId }
    /// The pot the carrier held under the lasting id at the last reading
    /// in this process, with the carrier and the owner it was read under:
    /// what another device's writing grows from. A reading under another
    /// carrier or another owner is no such base, so the first reading
    /// after a change of either never counts as growth.
    private var ownPotSeen: (pot: ListeningStatsData, carrier: Int, owner: String?)?

    /// Another device writes under this device's id
    /// (`ListeningStatsSync.anotherDeviceWrites`): this device takes a fresh
    /// id from the next start and writes nothing under the shared one
    /// before. The pot under it stays: it is the other device's.
    private func noteOwnPot(_ pots: [String: ListeningStatsData]) {
        guard firstStandUntil == nil, let lasting = lastingDeviceId(), let observed = pots[lasting] else { return }
        let carrierNow = generation.current
        let ownerNow = identity()
        let previous = ownPotSeen.flatMap { $0.carrier == carrierNow && $0.owner == ownerNow ? $0.pot : nil }
        defer { ownPotSeen = (observed, carrierNow, ownerNow) }
        guard ListeningStatsSync.anotherDeviceWrites(observed: observed, previous: previous, own: ownerPot) else { return }
        Logger.library.notice("STATS another device writes under this device's id, it is left")
        _ = deviceIds.leave()
    }

    /// Whether the held start may end now: the lasting id is held, and the
    /// carrier delivered or the limit passed. The limit never ends a hold
    /// for the id.
    private func firstStandMayEnd() -> Bool {
        guard let until = firstStandUntil, lastingDeviceId() != nil else { return false }
        return carrier.hasDeliveredFirst || ContinuousClock.now >= until
    }

    /// How long a start without rows holds its pot for a carrier that does
    /// not deliver (no account, no network). Chosen, not measured: what
    /// the far side delivers after it can be replaced by this device's pot.
    nonisolated static let firstStandLimit: Duration = .seconds(120)
    private let firstStandWait: Duration

    /// Until when a start without rows holds its pot for the carrier's
    /// first state; nil while nothing is held. The limit is asked at the
    /// next publish, so a carrier that never delivers holds nothing past
    /// the first pause after it.
    private var firstStandUntil: ContinuousClock.Instant?
    /// Whether the held start adds the pot to what this run counted
    /// (`addedHeldPot`): it found the rows fresh, and this process has not
    /// published yet, so no pot holds anything of this run. Written either
    /// way, though this run may have counted and written since.
    private var heldStartAddsPot = false
    /// Whether this process sent its pot to a carrier: from then on a pot
    /// may hold this run's seconds, and no hold adds a pot any more.
    private var publishedInThisProcess = false

    /// Nothing is published until the carrier delivered the far side once
    /// or the limit passed; then the own pot is taken back as at a start.
    private func holdForFirstStand() {
        firstStandUntil = ContinuousClock.now + firstStandWait
        if case .fresh = rowBase, !publishedInThisProcess { heldStartAddsPot = true } else { heldStartAddsPot = false }
        Logger.library.notice("STATS publish held: the carrier=\(self.carrier.name, privacy: .public) has not delivered its first state")
    }

    private func endFirstStandHold(by caller: String) {
        guard firstStandUntil != nil else { return }
        firstStandUntil = nil
        Logger.library.notice("STATS first state by=\(caller, privacy: .public) carrier=\(self.carrier.name, privacy: .public)")
        adoptOwnPot(asFreshStart: heldStartAddsPot)
        publish()
        recompose()
    }

    /// This device's own published pot back into the stock when the rows
    /// could not be read (`ListeningStatsSync.adoptedOwnPot`): written after
    /// a fresh start; over unread rows only shown and published, and held
    /// apart, so the read that comes later can tell the pot from what this
    /// run counted (`rowsReadForWrite`). `asFreshStart` is a fresh start
    /// that held for the first state before this process published: it may
    /// have counted and written since, and the pot is added to that and
    /// written.
    private func adoptOwnPot(asFreshStart: Bool) {
        // Taken back under the lasting id only: under an id for this
        // process the carrier holds nothing of this device.
        guard let lasting = lastingDeviceId() else { return }
        let ownPot = carrier.pots()[lasting]
        // The published pot is the account's (`ownerPot`); the rows are the
        // device's. Without the ledger the two cannot be told apart.
        guard rereadLedgerIfUnread() else {
            Logger.library.notice("listening stats: own pot not taken back, the ledger is unread")
            return
        }
        let devicePot = ownPot.map { ListeningStatsSync.deviceSpace(pot: $0, carried: ledger.carried, since: ledger.since) }
        // A fresh start that held its publish before this process published
        // adds the pot to what it counted since (`addedHeldPot`); every
        // other start takes the larger value per key.
        let taken = asFreshStart
            ? ListeningStatsSync.addedHeldPot(own: ownData, pot: devicePot)
            : ListeningStatsSync.adoptedOwnPot(takesBack: ListeningStatsSync.takesOwnPotBack(rowBase),
                                               own: ownData, pot: devicePot)
        if let adopted = taken {
            let writes = asFreshStart || ListeningStatsSync.adoptionWrites(rowBase)
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
    /// the rows are known. Only the unread tables are read again, each on
    /// its own and off the main actor, since this repeats on every held save.
    /// While any table stays unread, the day table too, which names no title:
    /// every write holds, the Navidrome move answers "not now" (`rekeyItems`)
    /// and with it the cover sweep keeps waiting (`isPending`), over every
    /// restart until the table reads. Held is said once per run in the sync
    /// history and on the statistics page as long as it lasts (`rowsHeld`).
    private func rowsReadForWrite() async -> Bool {
        guard unreadDays || unreadItems else { return true }
        let database = self.database
        let askDays = unreadDays, askItems = unreadItems
        // One read at a time: a caller that comes while one runs (the save
        // chain and the move) awaits the same read instead of a second one.
        let read: Loads
        if let running = rereading {
            read = await running.value
        } else {
            // detached because the synchronous read must not run on the main
            // actor, and it repeats on every held save while a table stays unread.
            let task = Task.detached(priority: .utility) {
                Self.readTables(database, days: askDays, items: askItems)
            }
            rereading = task
            read = await task.value
            rereading = nil
        }
        // Another caller may have finished the read while this one waited.
        // Both marks clear together, below, so either one still set means
        // no caller applied a read yet.
        guard unreadDays || unreadItems else { return true }
        let days = unreadDays ? read.days : readAtStart.days
        let items = unreadItems ? read.items : readAtStart.items
        guard let days, let items else {
            Logger.library.notice("STATS save held: rows still not read days=\(days != nil) items=\(items != nil)")
            noteHeld()
            return false
        }
        rowsHeld = false
        ownData = ListeningStatsSync.rebuilt(own: ownData, held: potHeld,
                                             readDays: unreadDays ? days.rows : nil,
                                             readItems: unreadItems ? items.rows : nil)
        rowBase = Self.startBase(days: days, items: items).base
        if case .unknown = rowBase { startMissedRows = true } else { startMissedRows = false }
        Logger.library.notice("STATS rows read on save: days=\(days.rows.count) items=\(items.rows.count) plan=\(String(describing: self.rowBase.plan), privacy: .public)")
        potHeld = nil
        unreadDays = false
        unreadItems = false
        readAtStart = (nil, nil)
        recompose()
        return true
    }

    /// The held write, visible: the page's line while it holds, and one
    /// failed entry in the sync history per run, not one per held save.
    private func noteHeld() {
        rowsHeld = true
        guard !heldNoted else { return }
        heldNoted = true
        history.append(SyncHistory.entry(
            service: .statistics, direction: .up, counters: [], duration: 0,
            error: String(localized: "The listening statistics cannot be read, so the listening time of this session is not saved."),
            deviceId: SyncHistoryStore.entryDeviceId))
    }

    // MARK: - The owner of the totals

    /// The account signed in now (`AccessFollowers.identity`), nil when none
    /// is, and where the totals of another account rest. Only the app's
    /// store has them; every other one keeps no owner and shows the device.
    private let identity: () -> String?
    private let shelf: RestingShelf?
    /// The family's way through the shelf (`ShelfFollower`); nil without one.
    private lazy var follower: ShelfFollower? = shelf.map {
        ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "STATS")
    }
    private static let shelfFamily = "stats"
    private static let ledgerFamily = "statsLedger"
    private static let ledgerOwner = "device"

    /// The base of the account that holds the device: its rest when it
    /// took the device over, and the device's totals at that moment
    /// (`ListeningStatsSync.owned`). Empty before the first change of
    /// account, so the first account owns the device's whole history.
    nonisolated struct Ledger: Codable, Equatable {
        var carried = ListeningStatsData()
        var since = ListeningStatsData()
    }
    private var ledger = Ledger()
    /// The ledger could not be read. Until it is, this device shows and
    /// publishes nothing of its own (its whole history would count as the
    /// account's), and the statistics page says so.
    @Published private(set) var ledgerUnread = false

    /// What the account that holds the device listened to here: what is
    /// shown beside the other devices, and what is published. Nothing while
    /// the ledger is unread: no number of another account, and `publish`
    /// holds then, with or without an identity, so no empty pot goes up.
    var ownerPot: ListeningStatsData {
        Self.ownerPot(device: ownData, ledger: ledger, unread: ledgerUnread)
    }

    private static func ownerPot(device: ListeningStatsData, ledger: Ledger, unread: Bool) -> ListeningStatsData {
        guard !unread else { return ListeningStatsData() }
        return ListeningStatsSync.owned(device: device, carried: ledger.carried, since: ledger.since)
    }

    /// An unreadable ledger is read again, the way unread tables are;
    /// true once it is read.
    @discardableResult
    private func rereadLedgerIfUnread() -> Bool {
        guard ledgerUnread else { return true }
        guard let shelf else { return false }
        do {
            ledger = try shelf.rest(Ledger.self, of: Self.ledgerFamily, owner: Self.ledgerOwner) ?? Ledger()
            ledgerUnread = false
            Logger.library.notice("STATS ledger read again")
            recompose()
            return true
        } catch {
            Logger.library.debug("STATS ledger still unreadable reason=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whether the totals belong to the account signed in now, handing them
    /// over first by the shelf's one rule (`RestingShelf.handOver`): the
    /// holder's own totals rest on the shelf, and the new account's rest
    /// becomes the base, counted from the device's totals of now. Nothing
    /// of the device's rows is removed. False while it cannot (a table or
    /// the ledger unread, the shelf not writable); nothing is published
    /// then, since it would publish the holder's totals for the account.
    private func followsTheAccount(previous: String? = nil) -> Bool {
        guard let follower, let shelf, let scope = identity() else { return true }
        rereadLedgerIfUnread()
        guard let step = follower.follow(
            to: scope, previous: previous, unread: unreadDays || unreadItems || ledgerUnread, landing: .now,
            current: { ownerPot },
            replace: { rest, _, _ in
                let next = Ledger(carried: rest ?? ListeningStatsData(), since: ownData)
                try shelf.lay(next, of: Self.ledgerFamily, owner: Self.ledgerOwner)
                ledger = next
            }) else { return false }
        switch step {
        case .kept, .first: break
        case .unread:
            Logger.library.notice("STATS owner held: rows or ledger unread")
            return false
        case .moved:
            Logger.library.notice("STATS owner moved days=\(self.ownerPot.secondsPerDay.count)")
            recompose()
        }
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
        if firstStandMayEnd() { endFirstStandHold(by: carrier.hasDeliveredFirst ? "delivered" : "limit") }
        foreign = carrier.pots()
        noteOwnPot(foreign)
        recompose()
    }

    /// This device's pot to the carrier, as it stands right now. On a
    /// carrier with a ceiling only the live items travel, capped
    /// (everything that has a position already carries its time in a
    /// channel that syncs); on a carrier with room the whole pot does.
    private func publish() {
        guard AppStorageKeys.syncAcrossDevicesEnabled else { return }
        // A start without rows writes nothing before the far side was read:
        // it may hold this device's own pot from before.
        if firstStandUntil != nil {
            guard firstStandMayEnd() else {
                Logger.library.notice("STATS publish held: the first state or the lasting device id has not arrived")
                return
            }
            endFirstStandHold(by: carrier.hasDeliveredFirst ? "delivered" : "limit")
            return
        }
        guard let lasting = lastingDeviceId() else {
            Logger.library.notice("STATS publish held: no lasting device id")
            return
        }
        guard followsTheAccount() else {
            Logger.library.notice("STATS publish held: the totals wait for their owner")
            return
        }
        // Not only behind an identity: signed out of the service, the pot
        // would go up empty over the other carrier and zero this device.
        guard rereadLedgerIfUnread() else {
            Logger.library.notice("STATS publish held: the ledger is unread")
            return
        }
        let owned = ownerPot
        let pot = carrier.hasRoomLimit
            ? ListeningStatsSync.publishable(owned, itemCap: ListeningStatsSync.itemPotCap)
            : owned
        carrier.publish(pot, deviceId: lasting, by: "stats")
        publishedInThisProcess = true
    }

    /// How often the pots were merged, counted for the witness of the
    /// per-second work.
    private(set) var merges = 0

    /// Something the sum is made of changed: the sum is dropped, a surface
    /// that reads it merges again.
    private func recompose() {
        composed = nil
        objectWillChange.send()
    }

    private func compose() -> ListeningStatsData {
        let signpost = PerfSignpost.statsMerge()
        defer { signpost.end() }
        merges += 1
        return ListeningStatsSync.merged(local: ownerPot, ownDeviceId: ownDeviceId, foreign: foreign)
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
    /// (`NavidromeRekey.summed`); returns how many keys changed and how many
    /// there are. The days stay as they are, they name no title. A table
    /// the start could not read is read first; nil while it still cannot be
    /// read, because its rows hold titles under ids this memory lacks.
    @discardableResult
    func rekeyItems(_ map: (String) -> String) async -> (changed: Int, total: Int)? {
        guard await rowsReadForWrite() else { return nil }
        // The ledger and the totals resting for other accounts name titles
        // too; they move first, and a move that does not land holds the step.
        guard rereadLedgerIfUnread(), moveResting(map) else { return nil }
        let total = ownData.secondsPerItem.count
        let changed = NavidromeRekey.changedCount(ownData.secondsPerItem.keys, map)
        guard changed > 0 else { return (0, total) }
        ownData.secondsPerItem = NavidromeRekey.summed(ownData.secondsPerItem, map)
        // The held part moves with the keys, or the read that comes later
        // would count the pot as this run's listening under the new key.
        if let held = potHeld {
            potHeld = ListeningStatsData(secondsPerDay: held.secondsPerDay,
                                         secondsPerItem: NavidromeRekey.summed(held.secondsPerItem, map))
        }
        recompose()
        save()
        return (changed, total)
    }

    /// The ledger and every account's resting totals with their titles in
    /// the form `map` gives, laid and read back; false when one did not land.
    private func moveResting(_ map: (String) -> String) -> Bool {
        guard let shelf else { return true }
        func moved(_ data: ListeningStatsData) -> ListeningStatsData {
            ListeningStatsData(secondsPerDay: data.secondsPerDay,
                               secondsPerItem: NavidromeRekey.summed(data.secondsPerItem, map))
        }
        do {
            // The other accounts' totals first: they never meet this
            // account's numbers, and moving one twice changes nothing, so a
            // throw here leaves the ledger and the device's totals together
            // in the old space and a later run moves the rest.
            for owner in try shelf.owners(of: Self.shelfFamily) {
                guard let rest = try shelf.rest(ListeningStatsData.self, of: Self.shelfFamily, owner: owner) else { continue }
                let next = moved(rest)
                if next != rest { try shelf.lay(next, of: Self.shelfFamily, owner: owner) }
            }
            // The ledger last, right before the device's totals: its titles
            // move with the device's, or the subtraction would meet them
            // under two names.
            let movedLedger = Ledger(carried: moved(ledger.carried), since: moved(ledger.since))
            if movedLedger != ledger {
                try shelf.lay(movedLedger, of: Self.ledgerFamily, owner: Self.ledgerOwner)
                ledger = movedLedger
            }
            return true
        } catch {
            Logger.library.error("STATS resting totals not moved reason=\(String(describing: error), privacy: .public)")
            return false
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
        ListeningStatsSync.overview(pots: foreign, ownDeviceId: ownDeviceId)
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
            guard let self, await self.rowsReadForWrite() else { return }
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

    /// The stock follows a change of account at the moment of the change,
    /// with the sync switch off as well (`AccessFollower.followOwner`).
    func followOwner(previous: String?) {
        _ = followsTheAccount(previous: previous)
    }

    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        follow(StatsCarriers.make(), signedIn: signedIn, identityChanged: identityChanged, by: caller)
    }
}
