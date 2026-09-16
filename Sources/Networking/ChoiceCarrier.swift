// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The transport behind the travelling user choices. A carrier holds the
/// blob the far side has and takes the one this device merged, nothing
/// more: every rule (per key the last user action wins by its event time,
/// tombstones, the weakest legacy statements, adoption) stays in
/// `UserChoiceCloudSync`. The key-value store is the first carrier; the Mär
/// sync service and CloudKit hang in here after, the same three answers the
/// pot, the claim, the statistics and the playlists give.
///
/// The unit is the whole blob (`cloudKey → {v, t, d}` as plist values),
/// because the merge decides per key over the union of both sides and a
/// carrier that spoke single keys could not tell a cleared key from an
/// unknown one.
@MainActor
protocol ChoiceCarrier: AnyObject {
    /// A short name for the log line that says which carrier runs.
    var name: String { get }
    /// The blob as the far side holds it, as far as this carrier knows.
    func loadBlob() -> [String: Any]
    /// Store the merged blob. Whole or as a difference is the carrier's
    /// business; the runner hands over the state it wants held.
    func storeBlob(_ blob: [String: Any])
    /// One list of the old premium-classification channel, by its key. Only
    /// the key-value store ever carried those lists; every other carrier
    /// answers nil, and the runner then folds nothing.
    func legacyList(forKey key: String) -> [String]?
    /// Flush what is pending now. The key-value store coalesces by itself,
    /// so there this only nudges.
    func flush()
    /// Starts delivery. `onChange` fires on main whenever the far side
    /// moved; the runner re-reads, merges and decides.
    func start(onChange: @escaping @MainActor () -> Void)
}

/// Which carrier the choices run on: the Mär sync service when the person
/// set one up, otherwise CloudKit on a device (the key-value store as its
/// fallback and legacy reader), and the key-value store alone on a DEBUG
/// simulator so no test writes a person's CloudKit container. The same
/// question the pot, the claim, the statistics and the playlists ask,
/// answered the same way.
@MainActor
enum ChoiceCarriers {
    static func make(access: MaerSyncAccess? = MaerSyncAccess.stored()) -> any ChoiceCarrier {
        // Noted where it is DECIDED. A surface that asked a runner
        // instead would create it, and the question would make its
        // own answer true.
        CarrierChoices.note(service: access != nil)
        if access != nil { return MaerSyncChoiceCarrier(session: MaerSyncCarriers.session) }
        let keyValue = KeyValueChoiceCarrier()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" { return keyValue }
        #endif
        return CloudKitChoiceCarrier(database: CKChoiceDatabase(), fallback: keyValue)
    }
}

/// The key-value store as carrier: ONE consolidated key holding the blob,
/// via the same `NSUbiquitousKeyValueStore` the podcast progress uses. One
/// key, not a key per choice, stays clear of the store's 1024-key limit.
/// Without the iCloud capability the store stays silent and everything
/// keeps working locally. The legacy lists live in the same store under
/// their own keys and are read as they are.
@MainActor
final class KeyValueChoiceCarrier: ChoiceCarrier {
    let name = "kvs"
    nonisolated static let blobKey = "userChoices"
    private let store: any UserChoiceCloudStore
    private var onChange: (@MainActor () -> Void)?
    /// Must never exceed 1. A second observer would double every reconcile.
    private(set) var observerRegistrations = 0

    init(store: any UserChoiceCloudStore = CloudKeyValue.store) {
        self.store = store
    }

    func loadBlob() -> [String: Any] {
        store.dictionary(forKey: Self.blobKey) ?? [:]
    }

    func storeBlob(_ blob: [String: Any]) {
        store.set(blob, forKey: Self.blobKey)
        // No per-write synchronize: the store coalesces on its own; the
        // explicit flush runs at start and reconcile, where it pays.
    }

    func legacyList(forKey key: String) -> [String]? {
        store.array(forKey: key) as? [String]
    }

    func flush() {
        _ = store.synchronize()
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard observerRegistrations == 0 else { return }
        observerRegistrations += 1
        // Observes the store it was given, so a fake never listens to the
        // real one; an in-memory store posts nothing and is observed as
        // "any sender", which no test host ever posts.
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store as? NSUbiquitousKeyValueStore)
        _ = store.synchronize()
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
}
