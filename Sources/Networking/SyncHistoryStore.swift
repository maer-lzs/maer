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
/// `sync_last_checked`. The two documents of the builds before are read
/// only when their rows hold nothing, poured once and set aside. An entry
/// a build cannot decode (a service case it does not know) is one skipped
/// row, never the whole ring.
@MainActor
final class SyncHistoryStore: ObservableObject, SyncHistoryStoring {
    static let shared = SyncHistoryStore(database: MaerDatabase.shared, ablage: .documents)

    @Published private(set) var entries: [SyncHistoryEntry] = []
    /// Newest "checked" moment per service (rawValue key), shown in the
    /// history header. Updated by every check. Also the ones that leave no ring
    /// entry (clean ABS flush, live music refresh).
    @Published private(set) var lastChecked: [String: Date] = [:]

    /// The seam to disk for the documents of the builds before: both lived
    /// beside each other.
    private let ablage: Ablage
    private let entriesName: String
    private let lastCheckedName: String
    private let entriesKeeper: RowKeeper<SyncHistoryEntry>
    private let checkedKeeper: RowKeeper<Date>

    /// - Parameter entriesName: the ring document's name; the stamps
    ///   document is its sibling `<name>.lastchecked.json`, keyed to it, so
    ///   an injected test name gets its own pair.
    init(database: MaerDatabase, ablage: Ablage, entriesName: String = "syncHistory.json") {
        self.ablage = ablage
        self.entriesName = entriesName
        self.lastCheckedName = URL(fileURLWithPath: entriesName).deletingPathExtension()
            .appendingPathExtension("lastchecked.json").lastPathComponent
        self.entriesKeeper = RowKeeper(database: database, table: .syncHistory, label: "HISTORY")
        self.checkedKeeper = RowKeeper(database: database, table: .syncLastChecked, label: "HISTORY checked")
        loadEntries()
        loadChecked()
    }

    /// The rows first; the document only when the rows hold nothing,
    /// poured once. A failed row read falls back to the document that was
    /// set aside and migrates nothing.
    private func loadEntries() {
        let start = entriesKeeper.startNow()
        var loaded = start.rows
        var document: URL?
        if loaded == nil {
            // A failed load is never silent: the seam logs it and parks the
            // unreadable file as evidence; the rows then start fresh.
            if let decoded = ablage.loadNow([SyncHistoryEntry].self, name: entriesName).value {
                loaded = Self.keyed(decoded)
                document = ablage.url(for: entriesName)
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow([SyncHistoryEntry].self, name: entriesName + ".migrated").value.map(Self.keyed)
                document = nil
            }
        }
        entries = SyncHistory.trimmed(Array((loaded ?? [:]).values))
        Logger.library.notice("sync history loaded: \(self.entries.count) entries migrate=\(document != nil)")
        if let document { entriesKeeper.pour(Self.keyed(entries), settingAside: [document]) }
    }

    private func loadChecked() {
        let start = checkedKeeper.startNow()
        var loaded = start.rows
        var document: URL?
        if loaded == nil {
            if let decoded = ablage.loadNow([String: Date].self, name: lastCheckedName).value {
                loaded = decoded
                document = ablage.url(for: lastCheckedName)
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow([String: Date].self, name: lastCheckedName + ".migrated").value
                document = nil
            }
        }
        lastChecked = loaded ?? [:]
        if let document, let loaded { checkedKeeper.pour(loaded, settingAside: [document]) }
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
        entriesKeeper.write(Self.keyed(entries))
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
        checkedKeeper.write(lastChecked)
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
