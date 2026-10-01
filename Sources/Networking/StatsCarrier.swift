// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The transport behind the listening statistics. One pot per device: a
/// carrier delivers this device's pot and holds every device's, nothing
/// more. Which pots count, how they add up and that the own mirror is
/// skipped stay the ONE rule in `ListeningStatsSync`. The key-value store
/// is the first carrier, the Mär sync service the second, CloudKit the
/// third; the seam is cut against all three at once, so no carrier's
/// habit (a ceiling, a cadence) becomes the store's.
@MainActor
protocol StatsCarrier: AnyObject {
    /// A short name for the log line that says which carrier runs.
    var name: String { get }
    /// Delivers this device's pot. Only the own pot is ever written;
    /// another device's is untouchable.
    func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String)
    /// Every pot the carrier holds, by device, the own one included when
    /// the carrier has it (the rule skips it).
    func pots() -> [String: ListeningStatsData]
    /// Starts delivery. `onChange` fires on main whenever a foreign pot
    /// arrived; the store re-reads and recomposes.
    func start(onChange: @escaping @MainActor () -> Void)
    /// One round of asking the other side now.
    func refresh(by caller: String) async
    /// Does this carrier have a ceiling that makes room matter? The
    /// key-value store holds one megabyte for everything, so there the
    /// item pot is capped and only the live items travel. A carrier with
    /// room carries every item: the caps are a price for a ceiling, not a
    /// rule about listening.
    var hasRoomLimit: Bool { get }
}

/// Which carrier the statistics run on: the Mär sync service when the
/// person set one up. Otherwise a DEBUG build on the simulator keeps to
/// the key-value carrier over the door's in-memory store, so no test and
/// no harness run ever writes a person's CloudKit container; the device
/// gets CloudKit with the key-value store as fallback and legacy reader.
/// The same three answers the pot gives.
@MainActor
enum StatsCarriers {
    static func make(access: MaerSyncAccess? = MaerSyncAccess.stored()) -> any StatsCarrier {
        if access != nil { return MaerSyncStatsCarrier(session: MaerSyncCarriers.session) }
        let keyValue = KeyValueStatsCarrier()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" { return keyValue }
        #endif
        return CloudKitStatsCarrier(database: CKStatsDatabase(), fallback: keyValue)
    }
}

/// The key-value store as carrier: one key per device
/// (`listeningStats.<deviceId>`), this device writes only its own, reads
/// all. No device ever touches a foreign value, so there is no write race
/// to lose time to. The same store as the podcast pot, and the same ONE
/// switch, whose reason is no longer the shared megabyte: since 3.0 the
/// statistics travel over their own CloudKit zone or over the service, and
/// the switch is one because the decision is one (see
/// `AppStorageKeys.syncAcrossDevicesEnabled`).
@MainActor
final class KeyValueStatsCarrier: StatsCarrier {
    let name = "kvs"
    let hasRoomLimit = true
    private let store: any UserChoiceCloudStore
    private let roomLimitBytes: Int
    private let onRefusal: @MainActor (RoomLimit.Reckoning) -> Void
    private var onChange: (@MainActor () -> Void)?

    /// `roomLimitBytes` is the ceiling the pot must fit under, and
    /// `onRefusal` is where a pot that does not fit is said out loud; a
    /// witness passes a small ceiling and a recorder.
    init(store: any UserChoiceCloudStore = CloudKeyValue.store,
         roomLimitBytes: Int = RoomLimit.potLimitBytes,
         onRefusal: @escaping @MainActor (RoomLimit.Reckoning) -> Void = { CloudQuotaWatch.refuse(pot: "listeningStats", $0) }) {
        self.store = store
        self.roomLimitBytes = roomLimitBytes
        self.onRefusal = onRefusal
    }

    func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
        // bearable, because two dictionaries of text and numbers always encode
        guard let encoded = try? JSONEncoder().encode(pot) else { return }
        let key = ListeningStatsSync.key(forDeviceId: deviceId)
        // The ceiling is reckoned BEFORE the write, beside what the store
        // holds under every other key; a pot that does not fit is refused
        // out loud instead of silently by the store.
        let reckoning = RoomLimit.reckon(bytes: encoded.count,
                                         otherBytes: RoomLimit.otherBytes(in: store.dictionaryRepresentation, besides: key),
                                         limit: roomLimitBytes)
        guard reckoning.fits else {
            Logger.library.error("KVS write REFUSED key=\(key, privacy: .public) bytes=\(reckoning.bytes) others=\(reckoning.otherBytes) limit=\(reckoning.limit) by=\(caller, privacy: .public)")
            onRefusal(reckoning)
            return
        }
        store.set(encoded, forKey: key)
    }

    func pots() -> [String: ListeningStatsData] {
        var out: [String: ListeningStatsData] = [:]
        for (key, value) in store.dictionaryRepresentation {
            guard let deviceId = ListeningStatsSync.deviceId(fromKey: key),
                  let data = value as? Data else { continue }
            // bearable, because an unreadable foreign pot counts as none; the device's next write replaces it
            guard let decoded = try? JSONDecoder().decode(ListeningStatsData.self, from: data) else { continue }
            out[deviceId] = decoded
        }
        return out
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store as? NSUbiquitousKeyValueStore)
        _ = store.synchronize()
    }

    /// The store delivers by itself; asking only nudges it.
    func refresh(by caller: String) async {
        let signpost = PerfSignpost.syncRound(.stats, .keyValue)
        defer { signpost.end() }
        _ = store.synchronize()
    }

    /// Only the REASON crosses the actor boundary, not the notification: a
    /// `Notification` is not `Sendable`, and the code is all this needs.
    /// It goes through the ONE watch, like every observer of the store.
    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.onChange?()
        }
    }
}
