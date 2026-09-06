// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The transport behind the listening-stand pot. A carrier holds and
/// delivers stands in the defaults shape (`[position, updatedAtMs,
/// duration?, form?]` per item id), nothing more: which side is newer,
/// what travels and what leaves the pot stay the ONE rule in
/// `PodcastCloudSync`. The key-value store is the first carrier; CloudKit
/// (decided D10 d, 06.09.) hangs in here next, the Mär sync service after
/// that, without touching the rule.
@MainActor
protocol StandCarrier: AnyObject {
    /// A short name for the log line that says which carrier runs.
    var name: String { get }
    /// Every stand the carrier holds, entries with at least a position and
    /// a moment.
    func stands() -> [String: [Double]]
    /// Upserts `upserts` and drops `removing`; the caller names itself for
    /// the log line.
    func write(upserts: [String: [Double]], removing: Set<String>, by caller: String)
    /// Starts delivery. `onChange` fires on main whenever a foreign write
    /// arrived; the runner takes it in and decides.
    func start(onChange: @escaping @MainActor () -> Void)
}

/// The key-value store as carrier: ONE consolidated key holding a dict
/// `id → entry` for every pot item. One key instead of thousands avoids
/// the store's 1024-key limit; the price is that every write uploads the
/// whole pot, which is why writers are bundled into one trailing write.
@MainActor
final class KeyValueStandCarrier: StandCarrier {
    nonisolated static let blobKey = "podcastProgress"

    let name = "kvs"
    private let cloud: any UserChoiceCloudStore
    private let spacingSeconds: Double
    private var onChange: (@MainActor () -> Void)?

    /// `spacingSeconds` is the least distance between two whole-pot
    /// writes; a witness passes zero to see every write land at once.
    init(cloud: any UserChoiceCloudStore = CloudKeyValue.store,
         spacingSeconds: Double = CloudSendRules.minSpacingSeconds) {
        self.cloud = cloud
        self.spacingSeconds = spacingSeconds
    }

    func stands() -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let raw: [String: Any] = cloud.dictionary(forKey: Self.blobKey) ?? [:]
        for (id, value) in raw {
            if let entry = Self.coerce(value), entry.count >= 2 { out[id] = entry }
        }
        return out
    }

    func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
        guard !upserts.isEmpty || !removing.isEmpty else { return }
        // A write during the trailing wait builds on the blob that is
        // queued, so nothing queued is lost to a later, smaller write.
        var blob = pendingBlob ?? cloud.dictionary(forKey: Self.blobKey) ?? [:]
        for id in removing { blob.removeValue(forKey: id) }
        for (id, entry) in upserts { blob[id] = entry }
        writeBlob(blob, by: caller)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore)
        _ = cloud.synchronize()
    }

    /// The reason goes through the ONE watch. Every observer of this
    /// notification asks WHY, none re-implements the comparison.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.onChange?()
        }
    }

    // MARK: - The one write of the blob

    private var lastBlobWriteAtMs: Double = 0
    private var pendingBlob: [String: Any]?
    private var pendingCaller = ""
    private var pendingWrite: Task<Void, Never>?

    /// Says how big the blob is and whether the store took it: the
    /// key-value store refuses a value silently, and a sync that "does
    /// nothing" must leave a number in the log. Writers arrive in bursts
    /// (play, seek, mark, foreground within seconds); the store uploads
    /// the whole pot each time, and the small claim beside it waits for
    /// that upload. A burst becomes ONE trailing write that carries the
    /// latest state: the first write goes at once, the next within the
    /// spacing waits and replaces whatever was queued.
    private func writeBlob(_ blob: [String: Any], by caller: String) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let wait = CloudSendRules.trailingWait(lastWriteAtMs: lastBlobWriteAtMs, nowMs: nowMs,
                                                  spacingSeconds: spacingSeconds) {
            pendingBlob = blob
            pendingCaller = caller
            guard pendingWrite == nil else { return }
            pendingWrite = Task { [weak self] in
                // tragbar, weil ein abgebrochener Schlaf den nachlaufenden Schrieb nur frueher laufen laesst
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, let queued = self.pendingBlob else { return }
                self.pendingWrite = nil
                self.pendingBlob = nil
                self.writeBlobNow(queued, by: self.pendingCaller + " (trailing)")
            }
            return
        }
        writeBlobNow(blob, by: caller)
    }

    private func writeBlobNow(_ blob: [String: Any], by caller: String) {
        lastBlobWriteAtMs = Date().timeIntervalSince1970 * 1000
        cloud.set(blob, forKey: Self.blobKey)
        _ = cloud.synchronize()
        // tragbar, weil die Byte-Zahl nur die Logzeile speist; -1 sagt, dass sie nicht zu haben war
        let bytes = (try? PropertyListSerialization.data(fromPropertyList: blob, format: .binary, options: 0))?.count ?? -1
        let readBack = cloud.dictionary(forKey: Self.blobKey)?.count ?? -1
        Logger.library.notice("KVS write key=\(Self.blobKey, privacy: .public) entries=\(blob.count) bytes=\(bytes) readBack=\(readBack) by=\(caller, privacy: .public)")
    }

    /// `[Double]` from a plist value (array of `Double`/`NSNumber`).
    nonisolated private static func coerce(_ value: Any) -> [Double]? {
        if let d = value as? [Double] { return d }
        if let n = value as? [NSNumber] { return n.map(\.doubleValue) }
        return nil
    }
}
