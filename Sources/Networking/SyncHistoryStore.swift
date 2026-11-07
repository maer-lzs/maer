// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog
import Synchronization

/// Narrow storage seam for the sync history. Stage 2 (iCloud mirror) and
/// the Android long-term goal swap the implementation behind this protocol;
/// neither is built now.
@MainActor
protocol SyncHistoryStoring: AnyObject {
    var entries: [SyncHistoryEntry] { get }
    func append(_ entry: SyncHistoryEntry)
    /// Record that a service ran a sync CHECK, without a ring entry.
    /// So a clean run (nothing changed, nothing queued) is still visible as a
    /// "last checked" timestamp. Keyed by `Service.rawValue`.
    func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date)
    var lastChecked: [String: Date] { get }
}

extension SyncHistoryStoring {
    func noteChecked(_ service: SyncHistoryEntry.Service) { noteChecked(service, at: Date()) }

    /// One rule for every runner: a run that moved something is a ring
    /// entry, a clean check is the service's stamp only. Both refresh the
    /// stamp (an entry implies a check), so the header says "checked"
    /// either way and the ring holds only what changed.
    func record(_ entry: SyncHistoryEntry, moved: Bool) {
        if moved {
            append(entry)
        } else {
            noteChecked(entry.service, at: entry.startedAt)
        }
    }
}

/// The ring (last 50 runs) as one row per entry in `sync_history` and the
/// per-service "last checked" stamps as one row per service in
/// `sync_last_checked`. An entry a build cannot decode (a service case it does not know) is one skipped
/// row, never the whole ring.
@MainActor
final class SyncHistoryStore: ObservableObject, SyncHistoryStoring {
    static let shared = SyncHistoryStore(database: MaerDatabase.shared)

    @Published private(set) var entries: [SyncHistoryEntry] = []
    /// Newest "checked" moment per service (rawValue key), shown in the
    /// history header. Updated by every check. Also the ones that leave no ring
    /// entry (clean ABS flush, live music refresh).
    @Published private(set) var lastChecked: [String: Date] = [:]

    private let entriesKeeper: RowKeeper<SyncHistoryEntry>
    private let checkedKeeper: RowKeeper<Date>

    init(database: MaerDatabase) {
        // Its own name: the listening history logs as HISTORY.
        self.entriesKeeper = RowKeeper(database: database, table: .syncHistory, label: "SYNCHISTORY")
        self.checkedKeeper = RowKeeper(database: database, table: .syncLastChecked, label: "SYNCHISTORY checked")
        entries = SyncHistory.trimmed(Array((entriesKeeper.startNow() ?? [:]).values))
        lastChecked = checkedKeeper.startNow() ?? [:]
        // Rows read after a failed start join the ring (trimmed again) and
        // the stamps (each stamp only moves forward).
        entriesKeeper.adopt = { [weak self] read in
            guard let self else { return }
            self.entries = SyncHistory.trimmed(Array(RowKeeper.union(read: read, run: Self.keyed(self.entries)).values))
        }
        checkedKeeper.adopt = { [weak self] read in
            guard let self else { return }
            self.lastChecked = read.merging(self.lastChecked) { max($0, $1) }
        }
        Logger.library.notice("sync history loaded: \(self.entries.count) entries")
    }

    /// The ring as rows: one per entry, keyed by the entry's stable id.
    private nonisolated static func keyed(_ entries: [SyncHistoryEntry]) -> [String: SyncHistoryEntry] {
        Dictionary(entries.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    /// Waits for every queued write (tests, teardown).
    func awaitPendingWrites() async {
        await entriesKeeper.awaitPendingWrites()
        await checkedKeeper.awaitPendingWrites()
    }

    func append(_ entry: SyncHistoryEntry) {
        entries = SyncHistory.trimmed([entry] + entries)
        // An entry always implies a fresh check of its service.
        setChecked(entry.service, at: entry.startedAt)
        Logger.library.notice("sync history append: \(entry.service.rawValue, privacy: .public) → \(self.entries.count) entries")
        // The trim's drop-outs become the diff's removals.
        entriesKeeper.write(emptying: .refused) { [weak self] in self.map { Self.keyed($0.entries) } }
    }

    func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date = Date()) {
        setChecked(service, at: date)
    }

    private var lastPersistedAt = Date.distantPast

    /// Monotonic per service. A stale/out-of-order call never moves the stamp
    /// backwards. The in-memory value (and the header) is always fresh; the
    /// row write is coalesced to at most every 30 s so the periodic playback
    /// sync (~every 5 s) can note its check without a write storm. A slightly
    /// stale persisted stamp across launches is fine for a reassurance
    /// timestamp.
    private func setChecked(_ service: SyncHistoryEntry.Service, at date: Date) {
        let key = service.rawValue
        if let existing = lastChecked[key], existing >= date { return }
        lastChecked[key] = date
        guard date.timeIntervalSince(lastPersistedAt) >= 30 else { return }
        lastPersistedAt = date
        checkedKeeper.write(emptying: .refused) { [weak self] in self?.lastChecked }
    }

    /// Stable device id (persistent random UUID. Portable to non-Apple
    /// platforms, unlike identifierForVendor). It lives in the keychain only
    /// (`DeviceIdOrigin`): the cloud pots are keyed by this id and grow
    /// forever, so a REINSTALL must keep the identity, and a backup must
    /// never hand it to a second device. Two devices sharing one pot id
    /// would silently corrupt the sums.
    /// Held: the keychain is read once per process while it gives the id,
    /// and again only while it does not (`rereadDeviceIdIfUnknown`).
    /// deviceId is read hot. Every diagnosis line, every claim poll, the
    /// mini player's per-second subtitle body. And a keychain round trip
    /// (IPC to securityd) per read is measurable load.
    /// This one tells own from foreign: the lasting id once it is held,
    /// before that an id for this process.
    nonisolated static var deviceId: String { holder.current }

    /// The id that may stand under anything that lasts (a pot, a claim, a
    /// document of the service, a row of this history): the keychain's,
    /// nil while the keychain does not give it out (before the first
    /// unlock). Nothing that lasts is written under an id for this process.
    nonisolated static var lastingDeviceId: String? { holder.lasting }

    /// What a history row carries: the lasting id, empty while none is held.
    nonisolated static var entryDeviceId: String { lastingDeviceId ?? "" }

    /// Posted on the main actor when the lasting id arrived in a process
    /// that ran without it; the writers that held send what waited.
    nonisolated static let deviceIdArrived = Notification.Name("SyncDeviceIdArrived")

    /// Reads the keychain again while no lasting id is held, and says so
    /// once it arrived. Called at the first unlock and at every return.
    @discardableResult
    static func rereadDeviceIdIfUnknown(by caller: String) -> Bool {
        guard holder.reread() else { return false }
        Logger.library.notice("SYNC device id arrived by=\(caller, privacy: .public)")
        NotificationCenter.default.post(name: deviceIdArrived, object: nil)
        return true
    }

    /// The id a sign-in to the service names: read again first, since a
    /// person who typed the sign-in has unlocked the device.
    static func deviceIdForSignIn() -> String {
        rereadDeviceIdIfUnknown(by: "sign-in")
        return deviceId
    }

    nonisolated private static let holder: DeviceIdHolder = {
        let holder = DeviceIdHolder(account: "syncHistoryDeviceId")
        // A copy in the defaults travels with a backup to another device.
        AppStorageKeys.remove("syncHistoryDeviceId")
        return holder
    }()
}

/// The device id of one keychain item, held for the process: the lasting
/// id once the keychain gave it, and until then an id for this process
/// only. A failed save of a fresh id leaves it for this process too, so
/// nothing lasts under an id the next process does not find.
nonisolated final class DeviceIdHolder: Sendable {
    private struct State {
        var lasting: String?
        var process: String
    }

    private let account: String
    private let reading: @Sendable (String) -> KeychainRead
    private let saving: @Sendable (String, String) -> Bool
    private let state: Mutex<State>

    /// `reading` and `saving` are the keychain; a witness hands in its own.
    init(account: String,
         reading: @escaping @Sendable (String) -> KeychainRead = { KeychainStore.read(forKey: $0) },
         saving: @escaping @Sendable (String, String) -> Bool = { account, id in
             // ThisDeviceOnly: kept across a reinstall on this device, never
             // restored onto another one.
             KeychainStore.save(id, forKey: account, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
         }) {
        self.account = account
        self.reading = reading
        self.saving = saving
        state = Mutex(Self.resolve(account: account, reading: reading, saving: saving, process: nil))
    }

    var current: String { state.withLock { $0.lasting ?? $0.process } }
    var lasting: String? { state.withLock { $0.lasting } }

    /// One more read while no lasting id is held; true when it arrived now.
    func reread() -> Bool {
        guard lasting == nil else { return false }
        let process = state.withLock { $0.process }
        let next = Self.resolve(account: account, reading: reading, saving: saving, process: process)
        return state.withLock { held in
            guard held.lasting == nil, let id = next.lasting else { return false }
            held = State(lasting: id, process: id)
            return true
        }
    }

    private static func resolve(account: String, reading: (String) -> KeychainRead,
                                saving: (String, String) -> Bool, process: String?) -> State {
        let origin = DeviceIdOrigin.of(reading(account), fresh: { UUID().uuidString })
        switch origin {
        case .kept(let id):
            return State(lasting: id, process: id)
        case .minted(let id):
            guard saving(account, id) else {
                Logger.library.error("SYNC device id not saved to the keychain, an id for this process only")
                return State(lasting: nil, process: process ?? id)
            }
            return State(lasting: id, process: id)
        case .forThisProcess(let id):
            Logger.library.notice("SYNC device id: the keychain is not readable now, an id for this process only")
            return State(lasting: nil, process: process ?? id)
        }
    }
}

/// Where this device's sync id comes from: the keychain alone. A value in
/// the defaults is never taken over, a restored backup brings the other
/// device's there. A keychain that cannot be read now (before the first
/// unlock) gets an id for this process only, never saved, so a later read
/// finds the item that is there. Bytes nothing reads are no id: reading
/// them again gives the same, so a fresh id is saved over them.
nonisolated enum DeviceIdOrigin: Equatable {
    /// The keychain holds it.
    case kept(String)
    /// The keychain holds none: a fresh id, to be saved on this device.
    case minted(String)
    /// The keychain says nothing now: a fresh id for this process.
    case forThisProcess(String)

    static func of(_ keychain: KeychainRead, fresh: () -> String) -> DeviceIdOrigin {
        switch keychain {
        case .value(let id) where !id.isEmpty: return .kept(id)
        case .value, .missing, .undecodable: return .minted(fresh())
        case .unreadable: return .forThisProcess(fresh())
        }
    }

    var id: String {
        switch self {
        case .kept(let id), .minted(let id), .forThisProcess(let id): id
        }
    }
}
