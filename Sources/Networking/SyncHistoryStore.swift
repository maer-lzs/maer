// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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
    /// platforms, unlike identifierForVendor). Keychain-first: the cloud pots
    /// are keyed by this id and grow forever, so a REINSTALL must keep the
    /// identity. Otherwise every reinstall orphans the old pot as a ghost
    /// no device can ever claim again. The defaults copy stays as a fast
    /// mirror and as the migration source for existing installs (their
    /// current id moves INTO the keychain, nothing rotates).
    /// Memoized: the resolution chain (defaults → keychain migration → mint)
    /// runs ONCE per process. deviceId is read hot. Every diagnosis line,
    /// every claim poll, the mini player's per-second subtitle body. And a
    /// keychain round trip (IPC to securityd) per read is measurable load.
    static let deviceId: String = {
        // ThisDeviceOnly: the id must survive a reinstall ON THIS DEVICE but
        // must never travel to a second device through a backup restore.
        // Two devices sharing one pot id would silently corrupt the sums.
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let existing = AppStorageKeys.string("syncHistoryDeviceId") {
            if KeychainStore.load(forKey: "syncHistoryDeviceId") == nil {
                KeychainStore.save(existing, forKey: "syncHistoryDeviceId",
                                   accessible: accessible)
            }
            return existing
        }
        if let kept = KeychainStore.load(forKey: "syncHistoryDeviceId") {
            AppStorageKeys.set(kept, for: "syncHistoryDeviceId")
            return kept
        }
        let fresh = UUID().uuidString
        AppStorageKeys.set(fresh, for: "syncHistoryDeviceId")
        KeychainStore.save(fresh, forKey: "syncHistoryDeviceId", accessible: accessible)
        return fresh
    }()
}
