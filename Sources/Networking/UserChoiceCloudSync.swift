// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The cloud side, injectable so the two-device merge is provable in units
/// (KVS does not run on the simulator; tests hand in a dictionary fake).
@MainActor
protocol UserChoiceCloudStore: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func array(forKey key: String) -> [Any]?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UserChoiceCloudStore {}

extension Notification.Name {
    /// Posted after a reconcile adopted foreign statements. userInfo["keys"]
    /// carries the touched defaults-level keys plus family markers
    /// ("radioFavorites", "recentSearches", "continueHiddenMarkers",
    /// "premiumClassification"). Observed sources re-read on it.
    static let userChoicesAdopted = Notification.Name("userChoicesAdopted")
}

/// Carries the travelling user choices between a person's devices — ONE
/// mechanism for every family member (sorts/filters, browse choices, standby
/// pointer, favorites, per-show settings, per-title tempo, searches, content
/// markers) instead of one hand-built sync per key.
///
/// Same channel discipline as the other cloud services: the ONE iCloud
/// switch, the shared KVS budget, the ONE quota watch. Storage is a single
/// blob key `userChoices` (`cloudKey → {v, t, d}`): one key instead of dozens
/// stays clear of the store's 1024-key limit.
///
/// Semantics (the invariants of the build order):
/// - Per key the last USER action wins, stamped with its EVENT time — writes
///   caused by mechanics (restore, cleanup, seeding) never note and never
///   stamp, so old knowledge cannot be re-stamped as new (the reviver class).
/// - "Never set" is the absence of an entry and beats nothing; a deliberate
///   clear is a TOMBSTONE with the clear's event time.
/// - Pre-family stock travels at t = 0: it loses against every real action
///   and wins only against devices that know nothing.
/// - Adoption writes the plain defaults keys (readers stay untouched) and
///   posts ONE notification for the observed sources.
@MainActor
final class UserChoiceCloudSync {
    static let shared = UserChoiceCloudSync()

    static let blobKey = "userChoices"
    static let stampsKey = "userChoiceStamps"
    // Legacy premium-classification channel (folded into the family): read on
    // EVERY reconcile as weakest (t = 0) statements, so a device still on the
    // old build keeps being heard until it updates.
    static let legacyMarkedKey = "premiumMarkedFeeds"
    static let legacyBlockedKey = "blockedFeedKeys"
    static let legacyMarkedRemovedKey = "premiumMarkedFeedsRemoved"
    static let legacyBlockedRemovedKey = "blockedFeedKeysRemoved"

    private let defaults: UserDefaults
    private let cloud: any UserChoiceCloudStore
    private let syncEnabled: () -> Bool
    /// Event clock in ms — injectable so merge ordering is deterministic in
    /// tests.
    private let now: () -> Double
    private var didStart = false
    /// True while adoption results are being applied/announced — a note that
    /// fires as an echo of adoption must align stamps, never re-stamp "now".
    private(set) var isAdopting = false

    init(defaults: UserDefaults = .standard,
         cloud: any UserChoiceCloudStore = NSUbiquitousKeyValueStore.default,
         syncEnabled: @escaping () -> Bool = { AppStorageKeys.podcastICloudSyncEnabled },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.defaults = defaults
        self.cloud = cloud
        self.syncEnabled = syncEnabled
        self.now = now
    }

    #if DEBUG
    /// The unit-test HOST must not touch the real KVS: other suites drive
    /// production write paths (sorts, rates, favorites) through the shared
    /// instance, and their notes would accumulate in the simulator's store
    /// across runs — every later host start would adopt that junk back
    /// (test-poisons-real-store class). Injected test instances carry their
    /// own fake cloud and stay fully live.
    private var sharedMustStaySilent: Bool {
        self === Self.shared
            && (UITestSeed.isActive
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
    #else
    private var sharedMustStaySilent: Bool { false }
    #endif

    func start() {
        if sharedMustStaySilent { return }
        guard syncEnabled() else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud as? NSUbiquitousKeyValueStore)
        _ = cloud.synchronize()
        reconcile()
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            CloudQuotaWatch.note(reason: reason)
            self.reconcile()
        }
    }

    // MARK: - Notes (the user-action entry points)

    /// A user set (or with `value == nil` deliberately cleared) a scalar
    /// choice. Stamps always (event times survive an off switch); the cloud
    /// write is gated on the switch.
    func noteScalar(key: String, value: Any?) {
        note(cloudKey: key, value: UserChoiceValue.from(plist: value))
    }

    func noteFavorite(_ station: RadioStation, added: Bool) {
        let value: UserChoiceValue? = added
            ? (try? JSONEncoder().encode(station)).map(UserChoiceValue.data)
            : nil
        note(cloudKey: UserChoiceCatalog.favoritePrefix + station.id, value: value)
    }

    func noteSearch(_ term: String, removed: Bool) {
        note(cloudKey: UserChoiceCatalog.searchPrefix + term,
             value: removed ? nil : .bool(true))
    }

    func noteSearchesCleared(_ terms: [String]) {
        for term in terms { noteSearch(term, removed: true) }
    }

    /// Hiding writes the marker VALUE (the progress stamp it was hidden at);
    /// an explicit un-hide is a tombstone. The derived return (newer progress
    /// re-shows the title) is mechanics and never notes.
    func noteHidden(id: String, marker: Double?) {
        note(cloudKey: UserChoiceCatalog.hiddenPrefix + id,
             value: marker.map(UserChoiceValue.double))
    }

    func notePremiumMark(_ feedKey: String, marked: Bool) {
        note(cloudKey: UserChoiceCatalog.premiumMarkPrefix + feedKey,
             value: marked ? .bool(true) : nil)
    }

    func noteFeedBlock(_ feedKey: String) {
        note(cloudKey: UserChoiceCatalog.feedBlockPrefix + feedKey, value: .bool(true))
    }

    private func note(cloudKey: String, value: UserChoiceValue?) {
        if sharedMustStaySilent { return }
        var stamps = localStamps()
        let now = now()
        guard syncEnabled() else {
            // Event time survives for the day the switch turns on.
            stamps[cloudKey] = now
            saveStamps(stamps)
            return
        }
        var blob = cloudBlob()
        let existing = UserChoiceEntry.from(plist: blob[cloudKey])
        if let existing, existing.value == value {
            // Same statement already in the cloud (adoption echo, or a
            // re-select of the same value): align the stamp, write nothing —
            // a fresh "now" here would re-stamp foreign knowledge as new.
            stamps[cloudKey] = max(stamps[cloudKey] ?? 0, existing.t)
            saveStamps(stamps)
            return
        }
        guard !isAdopting else {
            // A group echo during adoption (value differs only because the
            // echo raced the write): never stamp mechanics.
            return
        }
        stamps[cloudKey] = now
        saveStamps(stamps)
        blob[cloudKey] = UserChoiceEntry(value: value, t: now).plist
        // The cap must hold on the PUSH path too — a foregrounded device can
        // note hundreds of rates without ever reconciling in between.
        if cloudKey.hasPrefix("playbackRate.") {
            pruneOverflow(&blob)
        }
        saveBlob(blob)
    }

    // MARK: - Reconcile

    func reconcile() {
        if sharedMustStaySilent { return }
        guard syncEnabled() else { return }
        // A reconcile asks the CLOUD, never the mirror — a foreign device may
        // have written since the last read (the mirror only spares the notes).
        blobCache = nil
        var blob = cloudBlob()
        var stamps = localStamps()
        let localEntries = collectLocalEntries(stamps: stamps)
        let legacy = legacyStatements(blobKeys: Set(blob.keys))

        var blobChanged = false
        var adoptedScalarKeys: [String] = []
        var adoptedFavorites: [(station: RadioStation, t: Double)] = []
        var removedFavoriteIds: [String] = []
        var searchesTouched = false
        var hiddenTouched = false
        var premiumTouched = false

        let allKeys = Set(blob.keys).union(localEntries.keys).union(legacy.keys)
        for key in allKeys {
            let cloudEntry = UserChoiceEntry.from(plist: blob[key]) ?? legacy[key]
            let decision = UserChoiceMerge.decide(local: localEntries[key], cloud: cloudEntry)
            switch decision {
            case .none:
                continue
            case .push(let t):
                blob[key] = UserChoiceEntry(value: localEntries[key]?.value, t: t).plist
                blobChanged = true
            case .adoptStampOnly:
                if let cloudEntry { stamps[key] = cloudEntry.t }
            case .adopt:
                guard let cloudEntry else { continue }
                if apply(cloudEntry, forCloudKey: key,
                         adoptedScalarKeys: &adoptedScalarKeys,
                         adoptedFavorites: &adoptedFavorites,
                         removedFavoriteIds: &removedFavoriteIds,
                         searchesTouched: &searchesTouched,
                         hiddenTouched: &hiddenTouched,
                         premiumTouched: &premiumTouched) {
                    stamps[key] = cloudEntry.t
                    // A legacy-only statement that won gets a real blob entry,
                    // so the next device does not depend on the legacy keys.
                    if blob[key] == nil {
                        blob[key] = cloudEntry.plist
                        blobChanged = true
                    }
                }
            }
        }

        // Apply the collected family effects in one pass each.
        if !adoptedFavorites.isEmpty || !removedFavoriteIds.isEmpty {
            var list = RadioStore.favorites(defaults: defaults)
            list.removeAll { removedFavoriteIds.contains($0.id) }
            list = UserChoiceMerge.favoritesAppending(local: list, adopted: adoptedFavorites)
            RadioStore.replaceFavorites(list, defaults: defaults)
        }
        if searchesTouched {
            rebuildSearchList(blob: blob)
        }

        let beforePrune = blob.count
        pruneOverflow(&blob)
        if blobChanged || blob.count != beforePrune {
            saveBlob(blob)
            _ = cloud.synchronize()
        }
        saveStamps(stamps)

        let adoptedAnything = !adoptedScalarKeys.isEmpty || !adoptedFavorites.isEmpty
            || !removedFavoriteIds.isEmpty || searchesTouched || hiddenTouched || premiumTouched
        if adoptedAnything {
            var keys = adoptedScalarKeys
            if !adoptedFavorites.isEmpty || !removedFavoriteIds.isEmpty { keys.append("radioFavorites") }
            if searchesTouched { keys.append("recentSearches") }
            if hiddenTouched {
                keys.append("continueHiddenMarkers")
            }
            if premiumTouched { keys.append("premiumClassification") }
            Logger.library.notice("CHOICE sync adopted: \(keys.joined(separator: " "), privacy: .public)")
            isAdopting = true
            if hiddenTouched { NotificationCenter.default.post(name: .continueHiddenChanged, object: nil) }
            NotificationCenter.default.post(name: .userChoicesAdopted, object: nil,
                                            userInfo: ["keys": keys])
            isAdopting = false
        }
    }

    /// Applies one adopted statement. Returns false when the adoption is
    /// refused (the standby guard) — the stamp must then stay untouched so
    /// the entry is re-judged on every reconcile.
    private func apply(_ entry: UserChoiceEntry, forCloudKey key: String,
                       adoptedScalarKeys: inout [String],
                       adoptedFavorites: inout [(station: RadioStation, t: Double)],
                       removedFavoriteIds: inout [String],
                       searchesTouched: inout Bool,
                       hiddenTouched: inout Bool,
                       premiumTouched: inout Bool) -> Bool {
        if key.hasPrefix(UserChoiceCatalog.favoritePrefix) {
            let id = String(key.dropFirst(UserChoiceCatalog.favoritePrefix.count))
            if case .data(let data)? = entry.value,
               let station = try? JSONDecoder().decode(RadioStation.self, from: data) {
                adoptedFavorites.append((station, entry.t))
            } else {
                removedFavoriteIds.append(id)
            }
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.searchPrefix) {
            searchesTouched = true
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.hiddenPrefix) {
            let id = String(key.dropFirst(UserChoiceCatalog.hiddenPrefix.count))
            var markers = ContinueHiddenStore.markers(defaults: defaults)
            if case .double(let marker)? = entry.value { markers[id] = marker }
            else { markers.removeValue(forKey: id) }
            defaults.set(markers, forKey: AppStorageKeys.continueHiddenMarkers)
            hiddenTouched = true
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.premiumMarkPrefix) {
            let feed = String(key.dropFirst(UserChoiceCatalog.premiumMarkPrefix.count))
            adoptMembership(feed, present: entry.value != nil,
                            listKey: AppStorageKeys.premiumMarkedFeeds)
            premiumTouched = true
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.feedBlockPrefix) {
            let feed = String(key.dropFirst(UserChoiceCatalog.feedBlockPrefix.count))
            adoptMembership(feed, present: entry.value != nil,
                            listKey: AppStorageKeys.blockedFeedKeys)
            premiumTouched = true
            return true
        }
        // Scalar (static or dynamic-prefix) key.
        if key == AppStorageKeys.lastPlayedItemId, case .string(let id)? = entry.value,
           PlayerCoordinator.standbyCountsAsFinished(ListeningStore.mark(id, in: defaults)) {
            // d7f12e1 A, applied to adoption: a pointer that is finished by
            // local numbers is never adopted — and never stamps, so a later
            // un-finish re-offers it.
            return false
        }
        if let value = entry.value {
            defaults.set(value.plist, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        // The region's merged query names are a derived cache of the OLD
        // region — an adopted state must not query with them (the display
        // name works as fallback until the region is re-chosen).
        if key == AppStorageKeys.radioRegionState {
            defaults.removeObject(forKey: AppStorageKeys.radioRegionQueryNames)
        }
        adoptedScalarKeys.append(key)
        return true
    }

    private func adoptMembership(_ element: String, present: Bool, listKey: String) {
        var set = Set(defaults.stringArray(forKey: listKey) ?? [])
        if present { set.insert(element) } else { set.remove(element) }
        defaults.set(Array(set).sorted(), forKey: listKey)
    }

    /// The local truth as cloud-shaped entries: travelling scalars, dynamic
    /// families and the element-wise groups.
    private func collectLocalEntries(stamps: [String: Double]) -> [String: UserChoiceEntry] {
        var out: [String: UserChoiceEntry] = [:]
        func add(_ key: String, _ value: UserChoiceValue?) {
            if let entry = UserChoiceMerge.localEntry(value: value, stamp: stamps[key]) {
                out[key] = entry
            }
        }
        for key in UserChoiceCatalog.travelingScalars {
            add(key, UserChoiceValue.from(plist: defaults.object(forKey: key)))
        }
        for (key, raw) in defaults.dictionaryRepresentation() {
            guard UserChoiceCatalog.travelingPrefixes.contains(where: { key.hasPrefix($0) })
            else { continue }
            add(key, UserChoiceValue.from(plist: raw))
        }
        for station in RadioStore.favorites(defaults: defaults) {
            add(UserChoiceCatalog.favoritePrefix + station.id,
                (try? JSONEncoder().encode(station)).map(UserChoiceValue.data))
        }
        for term in RecentSearches.list(defaults: defaults) {
            add(UserChoiceCatalog.searchPrefix + term, .bool(true))
        }
        for (id, marker) in ContinueHiddenStore.markers(defaults: defaults) {
            add(UserChoiceCatalog.hiddenPrefix + id, .double(marker))
        }
        for feed in defaults.stringArray(forKey: AppStorageKeys.premiumMarkedFeeds) ?? [] {
            add(UserChoiceCatalog.premiumMarkPrefix + feed, .bool(true))
        }
        for feed in defaults.stringArray(forKey: AppStorageKeys.blockedFeedKeys) ?? [] {
            add(UserChoiceCatalog.feedBlockPrefix + feed, .bool(true))
        }
        // Keys the person deliberately CLEARED leave no value — their stamp is
        // the only trace, and it must travel as a tombstone.
        for (key, _) in stamps where out[key] == nil && isTravelingCloudKey(key) {
            out[key] = UserChoiceEntry(value: nil, t: stamps[key] ?? 0)
        }
        return out
    }

    private func isTravelingCloudKey(_ key: String) -> Bool {
        if UserChoiceCatalog.travelingScalars.contains(key) { return true }
        if UserChoiceCatalog.travelingPrefixes.contains(where: { key.hasPrefix($0) }) { return true }
        return [UserChoiceCatalog.favoritePrefix, UserChoiceCatalog.searchPrefix,
                UserChoiceCatalog.hiddenPrefix, UserChoiceCatalog.premiumMarkPrefix,
                UserChoiceCatalog.feedBlockPrefix].contains { key.hasPrefix($0) }
    }

    /// The old premium-classification channel as weakest statements (t = 0)
    /// for elements the blob does not carry yet. Read every reconcile — a
    /// device on the old build keeps writing these keys until it updates.
    private func legacyStatements(blobKeys: Set<String>) -> [String: UserChoiceEntry] {
        var out: [String: UserChoiceEntry] = [:]
        func fold(listKey: String, removedKey: String, prefix: String) {
            for feed in cloud.array(forKey: listKey) as? [String] ?? [] {
                let key = prefix + feed
                guard !blobKeys.contains(key) else { continue }
                out[key] = UserChoiceEntry(value: .bool(true), t: 0)
            }
            for feed in cloud.array(forKey: removedKey) as? [String] ?? [] {
                let key = prefix + feed
                guard !blobKeys.contains(key) else { continue }
                out[key] = UserChoiceEntry(value: nil, t: 0)
            }
        }
        fold(listKey: Self.legacyMarkedKey, removedKey: Self.legacyMarkedRemovedKey,
             prefix: UserChoiceCatalog.premiumMarkPrefix)
        fold(listKey: Self.legacyBlockedKey, removedKey: Self.legacyBlockedRemovedKey,
             prefix: UserChoiceCatalog.feedBlockPrefix)
        return out
    }

    /// Rebuilds the local recent-searches list from the merged element state
    /// (newest event first, capped) — order is time-derived here, unlike the
    /// favorites row.
    private func rebuildSearchList(blob: [String: Any]) {
        let localOrder = RecentSearches.list(defaults: defaults)
        var elements: [(String, UserChoiceEntry)] = []
        for (key, raw) in blob where key.hasPrefix(UserChoiceCatalog.searchPrefix) {
            guard let entry = UserChoiceEntry.from(plist: raw) else { continue }
            elements.append((String(key.dropFirst(UserChoiceCatalog.searchPrefix.count)), entry))
        }
        let merged = UserChoiceMerge.mergedSearches(
            elements: elements.map { (term: $0.0, entry: $0.1) },
            localOrder: localOrder, cap: RecentSearches.cap)
        defaults.set(merged, forKey: RecentSearches.storageKey)
    }

    private func pruneOverflow(_ blob: inout [String: Any]) {
        let rates = blob.compactMap { key, raw -> (String, Double)? in
            guard key.hasPrefix("playbackRate."),
                  let entry = UserChoiceEntry.from(plist: raw) else { return nil }
            return (key, entry.t)
        }
        for key in UserChoiceMerge.overflowKeys(
            entries: rates.map { (key: $0.0, t: $0.1) },
            cap: UserChoiceCatalog.playbackRateCap) {
            blob.removeValue(forKey: key)
        }
    }

    // MARK: - Stores

    /// In-memory mirror of the blob: notes fire on every user action (sort
    /// didSets, rate changes), and decoding the whole KVS dictionary per note
    /// measurably starved the main actor in the full suite. Invalidated on
    /// external change, write-through on save.
    private var blobCache: [String: Any]?

    private func cloudBlob() -> [String: Any] {
        if let blobCache { return blobCache }
        let blob = cloud.dictionary(forKey: Self.blobKey) ?? [:]
        blobCache = blob
        return blob
    }

    private func saveBlob(_ blob: [String: Any]) {
        blobCache = blob
        cloud.set(blob, forKey: Self.blobKey)
        // No per-note synchronize: KVS coalesces on its own; the explicit
        // flush runs at start/reconcile, where it pays for itself.
    }

    func localStamps() -> [String: Double] {
        defaults.dictionary(forKey: Self.stampsKey) as? [String: Double] ?? [:]
    }

    private func saveStamps(_ stamps: [String: Double]) {
        defaults.set(stamps, forKey: Self.stampsKey)
    }

    /// Serialized blob size — the budget witness for the diagnosis/report.
    func blobBytes() -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: cloudBlob(),
                                             format: .binary, options: 0))?.count ?? 0
    }
}
