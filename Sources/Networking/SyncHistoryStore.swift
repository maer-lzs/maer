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
}

/// Local JSON ring buffer (last 50 runs) in the Documents directory.
@MainActor
final class SyncHistoryStore: ObservableObject, SyncHistoryStoring {
    static let shared = SyncHistoryStore()

    @Published private(set) var entries: [SyncHistoryEntry] = []
    /// Newest "checked" moment per service (rawValue key), shown in the
    /// history header. Updated by every check. Also the ones that leave no ring
    /// entry (clean ABS flush, live music refresh).
    @Published private(set) var lastChecked: [String: Date] = [:]

    /// The seam to disk: both documents live beside each other.
    private let ablage: Ablage
    private let entriesName: String
    private let lastCheckedName: String

    /// Injectable file location for tests.
    init(fileURL: URL? = nil) {
        let entriesURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("syncHistory.json")
        self.ablage = Ablage(directory: entriesURL.deletingLastPathComponent())
        self.entriesName = entriesURL.lastPathComponent
        // Sibling of the entries file, keyed to its name. So an injected test
        // file gets its own last-checked store instead of a shared one.
        self.lastCheckedName = entriesURL.deletingPathExtension()
            .appendingPathExtension("lastchecked.json").lastPathComponent
        // A failed load is never silent: the seam logs it and parks the
        // unreadable file as evidence, so the next append cannot overwrite
        // it with a fresh ring.
        if let decoded = ablage.loadNow([SyncHistoryEntry].self, name: entriesName).value {
            entries = SyncHistory.trimmed(decoded)
            Logger.library.notice("sync history loaded: \(self.entries.count) entries")
        }
        if let decoded = ablage.loadNow([String: Date].self, name: lastCheckedName).value {
            lastChecked = decoded
        }
    }

    /// The last handed-over writes, so a caller can wait for them to land
    /// (tests, teardown). Held here because the hand-over to the seam is
    /// itself asynchronous.
    private var pendingEntriesWrite: Task<Void, Never>?
    private var pendingCheckedWrite: Task<Void, Never>?

    /// Waits for every queued write (tests, teardown).
    func awaitPendingWrites() async {
        await pendingEntriesWrite?.value
        await pendingCheckedWrite?.value
    }

    func append(_ entry: SyncHistoryEntry) {
        entries = SyncHistory.trimmed([entry] + entries)
        // An entry always implies a fresh check of its service.
        setChecked(entry.service, at: entry.startedAt)
        Logger.library.notice("sync history append: \(entry.service.rawValue, privacy: .public) → \(self.entries.count) entries")
        let ablage = ablage, name = entriesName, snapshot = entries
        // Each write waits for the one before it, so the last state lands
        // last (the seam orders by arrival, the store by intent).
        let previous = pendingEntriesWrite
        pendingEntriesWrite = Task(priority: .utility) {
            await previous?.value
            // A failure is logged by the seam; the in-memory list still
            // shows the run.
            try? await ablage.save(snapshot, name: name, isEmpty: snapshot.isEmpty)   // tragbar, weil die Naht den Fehlschlag loggt
        }
    }

    func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date = Date()) {
        setChecked(service, at: date)
    }

    private var lastPersistedAt = Date.distantPast

    /// Monotonic per service. A stale/out-of-order call never moves the stamp
    /// backwards. The in-memory value (and the header) is always fresh; the disk
    /// write is coalesced to at most every 30 s so the periodic playback sync
    /// (~every 5 s) can note its check without a write storm. A slightly stale
    /// persisted stamp across launches is fine for a reassurance timestamp.
    private func setChecked(_ service: SyncHistoryEntry.Service, at date: Date) {
        let key = service.rawValue
        if let existing = lastChecked[key], existing >= date { return }
        lastChecked[key] = date
        guard date.timeIntervalSince(lastPersistedAt) >= 30 else { return }
        lastPersistedAt = date
        let ablage = ablage, name = lastCheckedName, snapshot = lastChecked
        let previous = pendingCheckedWrite
        pendingCheckedWrite = Task(priority: .utility) {
            await previous?.value
            // A failure is logged by the seam; a stale reassurance stamp
            // across launches is fine.
            try? await ablage.save(snapshot, name: name, isEmpty: snapshot.isEmpty)   // tragbar, weil die Naht den Fehlschlag loggt
        }
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
