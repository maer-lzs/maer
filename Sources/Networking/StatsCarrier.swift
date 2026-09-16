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
        // Noted where it is DECIDED. A surface that asked a runner
        // instead would create it, and the question would make its
        // own answer true.
        CarrierChoices.note(service: access != nil)
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
    private var onChange: (@MainActor () -> Void)?

    init(store: any UserChoiceCloudStore = CloudKeyValue.store) {
        self.store = store
    }

    func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
        // tragbar, weil zwei Woerterbuecher aus Text und Zahlen immer kodieren
        guard let encoded = try? JSONEncoder().encode(pot) else { return }
        store.set(encoded, forKey: ListeningStatsSync.key(forDeviceId: deviceId))
    }

    func pots() -> [String: ListeningStatsData] {
        var out: [String: ListeningStatsData] = [:]
        for (key, value) in store.dictionaryRepresentation {
            guard let deviceId = ListeningStatsSync.deviceId(fromKey: key),
                  let data = value as? Data else { continue }
            // tragbar, weil ein unlesbarer fremder Topf wie keiner zaehlt; der naechste Schrieb des Geraets ersetzt ihn
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
