// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// F9: narrow storage seam for the sync history — stage 2 (iCloud mirror) and
/// the Android long-term goal swap the implementation behind this protocol;
/// neither is built now.
@MainActor
protocol SyncHistoryStoring: AnyObject {
    var entries: [SyncHistoryEntry] { get }
    func append(_ entry: SyncHistoryEntry)
    /// Y48/Y50: record that a service ran a sync CHECK, without a ring entry —
    /// so a clean run (nothing changed, nothing queued) is still visible as a
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
    /// Y48/Y50: newest "checked" moment per service (rawValue key), shown in the
    /// history header. Updated by every check — also the ones that leave no ring
    /// entry (clean ABS flush, live music refresh).
    @Published private(set) var lastChecked: [String: Date] = [:]

    private let fileURL: URL
    private let lastCheckedURL: URL

    /// Injectable file location for tests.
    init(fileURL: URL? = nil) {
        let entriesURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("syncHistory.json")
        self.fileURL = entriesURL
        // Sibling of the entries file, keyed to its name — so an injected test
        // file gets its own last-checked store instead of a shared one.
        self.lastCheckedURL = entriesURL.deletingPathExtension()
            .appendingPathExtension("lastchecked.json")
        // Y36 (Regel 3): a failed load must never be silent — a corrupt file
        // would drop the whole history and the next append would overwrite it.
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let data = try Data(contentsOf: self.fileURL)
                entries = SyncHistory.trimmed(try JSONDecoder().decode([SyncHistoryEntry].self, from: data))
                Logger.library.notice("sync history loaded: \(self.entries.count) entries")
            } catch {
                Logger.library.error("sync history load FAILED: \(error.localizedDescription, privacy: .public)")
                // Park the unreadable file as evidence — otherwise the next
                // append would silently overwrite it with a fresh ring.
                let parked = self.fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: parked)
                try? FileManager.default.moveItem(at: self.fileURL, to: parked)
            }
        }
        if let data = try? Data(contentsOf: self.lastCheckedURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastChecked = decoded
        }
    }

    func append(_ entry: SyncHistoryEntry) {
        entries = SyncHistory.trimmed([entry] + entries)
        // An entry always implies a fresh check of its service.
        setChecked(entry.service, at: entry.startedAt)
        Logger.library.notice("sync history append: \(entry.service.rawValue, privacy: .public) → \(self.entries.count) entries")
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The in-memory list still shows the run; only persistence failed.
            Logger.library.error("sync history write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date = Date()) {
        setChecked(service, at: date)
    }

    private var lastPersistedAt = Date.distantPast

    /// Monotonic per service — a stale/out-of-order call never moves the stamp
    /// backwards. The in-memory value (and the header) is always fresh; the disk
    /// write is coalesced to at most every 30 s so the periodic playback sync
    /// (~every 5 s) can note its check without a write storm — a slightly stale
    /// persisted stamp across launches is fine for a reassurance timestamp.
    private func setChecked(_ service: SyncHistoryEntry.Service, at date: Date) {
        let key = service.rawValue
        if let existing = lastChecked[key], existing >= date { return }
        lastChecked[key] = date
        guard date.timeIntervalSince(lastPersistedAt) >= 30 else { return }
        lastPersistedAt = date
        if let data = try? JSONEncoder().encode(lastChecked) {
            try? data.write(to: lastCheckedURL, options: .atomic)
        }
    }

    /// Stable per-install device id (persistent random UUID — portable to
    /// non-Apple platforms, unlike identifierForVendor).
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "syncHistoryDeviceId") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "syncHistoryDeviceId")
        return fresh
    }
}
