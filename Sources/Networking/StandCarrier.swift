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
    /// One round of asking the other side now (the foreground, the poll
    /// while playing). A carrier that is delivered to has nothing to do.
    func refresh(by caller: String) async
    /// Does this carrier have a ceiling that makes room matter? The
    /// key-value store holds one megabyte for everything, so finished
    /// episodes of unsubscribed shows are pruned there. A carrier with
    /// room keeps every stand: pruning is a price for a ceiling, not a
    /// rule about listening, and in a shared pot "unsubscribed here" is
    /// not "unsubscribed anywhere" (measured on 33: two devices removed
    /// and rewrote the same six stands every round).
    var hasRoomLimit: Bool { get }
    /// Which service the sync history names for a round over this
    /// carrier. The runner writes the history; it does not know what it
    /// runs on.
    var historyService: SyncHistoryEntry.Service { get }
    /// How often the player's tick asks this carrier for the other side
    /// while playing, in seconds. A number of the WAY: a carrier that is
    /// delivered to needs asking less often than one that is polled.
    var pullSeconds: Double { get }
    /// How often the playing device sends its state to the pot without a
    /// deliberate occasion, in seconds. The rest is events.
    var sendCadenceSeconds: Double { get }
}

extension StandCarrier {
    /// Carriers written before the question answer it the old way.
    var hasRoomLimit: Bool { true }
    /// The two iCloud carriers are iCloud to the history.
    var historyService: SyncHistoryEntry.Service { .iCloud }
    /// Every tick while playing: measured (D10 d), a silent push never
    /// reaches a locked, playing device, so the poll is the promise of the
    /// takeover on the iCloud carriers.
    var pullSeconds: Double { PlaybackClaimRules.tickSeconds }
    /// Once a minute on the iCloud carriers: measured before the rule,
    /// four whole-pot writes of 325 KB in 25 seconds, the class the
    /// key-value store throttles.
    var sendCadenceSeconds: Double { CloudSendRules.cadenceSeconds }
}

/// Which carrier the pot runs on. With a Mär sync service set up, the pot
/// runs on it. Otherwise a DEBUG build on the simulator keeps to the
/// key-value carrier over the door's in-memory store, so no test and no
/// harness run ever writes a person's CloudKit container; the device gets
/// CloudKit with the key-value store as fallback and legacy reader.
@MainActor
enum StandCarriers {
    static func make(access: MaerSyncAccess? = MaerSyncAccess.stored()) -> any StandCarrier {
        if access != nil { return MaerSyncStandCarrier(session: MaerSyncCarriers.session) }
        let keyValue = KeyValueStandCarrier()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" { return keyValue }
        #endif
        return CloudKitStandCarrier(database: CKStandDatabase(), fallback: keyValue)
    }
}

/// The mirror a carrier keeps in the key door: what the other side holds
/// as far as this device knows, and what is written here but not yet
/// accepted there. One encoding for every carrier that keeps one.
nonisolated enum StandMirrorStore {
    static func load(_ key: String, defaults: UserDefaults) -> [String: [Double]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        // tragbar, weil ein unlesbarer Spiegel nur einen vollen Abzug kostet; die Wahrheit liegt auf der anderen Seite und im Geraet
        return (try? JSONDecoder().decode([String: [Double]].self, from: data)) ?? [:]
    }

    static func loadList(_ key: String, defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: key) else { return [] }
        // tragbar, weil eine unlesbare Liste nur ein vergessenes Entfernen kostet, das der naechste Abgleich wiederholt
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ value: [String: [Double]], key: String, defaults: UserDefaults) {
        // tragbar, weil ein Woerterbuch aus Text und Zahlen immer kodiert
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    static func saveList(_ value: [String], key: String, defaults: UserDefaults) {
        // tragbar, weil eine Liste aus Text immer kodiert
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
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

    /// The store delivers by itself; asking only nudges it.
    func refresh(by caller: String) async {
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
