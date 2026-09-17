// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

extension Notification.Name {
    /// Posted after a reconcile adopted foreign statements. userInfo["keys"]
    /// carries the touched defaults-level keys plus family markers
    /// ("radioFavorites", "recentSearches", "continueHiddenMarkers",
    /// "premiumClassification"). Observed sources re-read on it.
    static let userChoicesAdopted = Notification.Name("userChoicesAdopted")
}

/// Carries the travelling user choices between a person's devices. ONE
/// mechanism for every family member (sorts/filters, browse choices, standby
/// pointer, favorites, per-show settings, per-title tempo, searches, content
/// markers) instead of one hand-built sync per key.
///
/// Same channel discipline as the other cloud services: the ONE iCloud
/// switch, the shared KVS budget, the ONE quota watch. Storage is ONE blob
/// (`cloudKey → {v, t, d}`) behind the `ChoiceCarrier` seam; the key-value
/// carrier keeps it under one key, clear of the store's 1024-key limit.
///
/// Semantics (the invariants of the build order):
/// - Per key the last USER action wins, stamped with its EVENT time. Writes
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
    static let shared = UserChoiceCloudSync(carrier: ChoiceCarriers.make())

    /// The blob's key belongs to the key-value carrier; kept here by name
    /// for the witnesses that read the fake store directly.
    static let blobKey = KeyValueChoiceCarrier.blobKey
    static let stampsKey = "userChoiceStamps"
    /// Unsubscribes made while the sync was off. See `SubscriptionRemovalRecord`.
    static let removalRecordKey = "userChoiceSubscriptionRemovals"
    // Legacy premium-classification channel (folded into the family): read on
    // EVERY reconcile as weakest (t = 0) statements, so a device still on the
    // old build keeps being heard until it updates.
    static let legacyMarkedKey = "premiumMarkedFeeds"
    static let legacyBlockedKey = "blockedFeedKeys"
    static let legacyMarkedRemovedKey = "premiumMarkedFeedsRemoved"
    static let legacyBlockedRemovedKey = "blockedFeedKeysRemoved"

    private let defaults: UserDefaults
    /// The transport. It holds and delivers the blob and answers the legacy
    /// lists; every rule of the merge stays here.
    private let carrier: any ChoiceCarrier
    private let syncEnabled: () -> Bool
    /// Event clock in ms. Injectable so merge ordering is deterministic in
    /// tests.
    private let now: () -> Double
    private var didStart = false
    /// True while adoption results are being applied/announced. A note that
    /// fires as an echo of adoption must align stamps, never re-stamp "now".
    private(set) var isAdopting = false
    /// Whether THIS device has a podcast server (gpodder or Audiobookshelf
    /// podcasts). Then the server is its truth for the subscription list and
    /// the travelling statements are never applied here; they are still
    /// noted, so a device without a server gets them.
    private let hasPodcastServer: () -> Bool
    /// The local subscriptions as the family sees them: feed key ⇒ feed
    /// address, or nil while the store has not loaded (then the family says
    /// nothing, and above all writes no tombstones).
    var localSubscriptions: () -> [String: String]? = { nil }
    /// Applies adopted subscription statements: feeds to follow (with the
    /// moment of subscribing) and feed keys to leave. Set by the store.
    var subscriptionAdopter: ((_ added: [(feedURL: String, t: Double)], _ removed: [String]) -> Void)?
    /// Collected during one reconcile, handed to the adopter once at its end.
    private var pendingSubscriptionsAdded: [(feedURL: String, t: Double)] = []
    private var pendingSubscriptionsRemoved: [String] = []

    init(defaults: UserDefaults = .standard,
         cloud: any UserChoiceCloudStore = CloudKeyValue.store,
         carrier: (any ChoiceCarrier)? = nil,
         syncEnabled: @escaping () -> Bool = { AppStorageKeys.syncAcrossDevicesEnabled },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
         hasPodcastServer: @escaping () -> Bool = { AppStorageKeys.hasPodcastServer }) {
        self.defaults = defaults
        // A carrier handed in wins. Else the store given (a test's dictionary
        // fake, or the door) becomes the key-value carrier, so every witness
        // that reads its fake directly keeps seeing the same blob.
        self.carrier = carrier ?? KeyValueChoiceCarrier(store: cloud)
        self.syncEnabled = syncEnabled
        self.now = now
        self.hasPodcastServer = hasPodcastServer
    }

    #if DEBUG
    /// The unit-test HOST must not touch the real KVS: other suites drive
    /// production write paths (sorts, rates, favorites) through the shared
    /// instance, and their notes would accumulate in the simulator's store
    /// across runs. Every later host start would adopt that junk back
    /// (test-poisons-real-store class). Injected test instances carry their
    /// own fake cloud and stay fully live.
    private var sharedMustStaySilent: Bool {
        self === Self.shared
            && (UITestSeed.isHarness
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
        // The carrier delivers: it flushes once on start and wakes the
        // reconcile whenever the far side moved.
        carrier.start { [weak self] in self?.reconcile() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(knownServersChanged),
            name: KnownServers.didChange, object: nil)
        reconcile()
    }

    /// The register of known addresses changed on this device: every entry
    /// travels as its own statement, a removed one as a tombstone.
    @objc private nonisolated func knownServersChanged(_ note: Notification) {
        let removed = note.userInfo?["removed"] as? String
        Task { @MainActor in self.noteKnownServers(removed: removed) }
    }

    /// Every entry travels as a value. A tombstone comes ONLY from a forget
    /// on this device (`removed`): an entry that is absent here may simply
    /// not have been adopted yet, and reading absence as deletion once
    /// raced a fresh sign-in against an arriving address.
    func noteKnownServers(removed: String? = nil) {
        for entry in KnownServers.all(defaults: defaults) {
            note(cloudKey: UserChoiceCatalog.knownServerPrefix + entry.id, value: .double(entry.lastSuccessAt))
        }
        if let removed {
            note(cloudKey: UserChoiceCatalog.knownServerPrefix + removed, value: nil)
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

    /// A station entered by hand: the statement carries the station, a
    /// removal is its tombstone. Same shape as the favourites.
    func noteManualStation(_ station: RadioStation, removed: Bool) {
        let value: UserChoiceValue? = removed
            ? nil
            // tragbar, weil ein Sender, der sich nicht kodieren laesst, keine Aussage ist
            : (try? JSONEncoder().encode(station)).map(UserChoiceValue.data)
        note(cloudKey: UserChoiceCatalog.manualStationPrefix + station.id, value: value)
    }

    /// A chosen stream variant of a station; nil means the choice was
    /// cleared and the station follows the catalogue's best again.
    func noteVariant(key: String, streamURL: String?) {
        note(cloudKey: UserChoiceCatalog.variantPrefix + key,
             value: streamURL.map(UserChoiceValue.string))
    }

    /// A station played: the statement carries the station, its time is the
    /// play moment. Removal from "Listen Again" is the tombstone.
    func noteRecentStation(_ station: RadioStation, removed: Bool) {
        let value: UserChoiceValue? = removed
            ? nil
            // tragbar, weil ein Sender, der sich nicht kodieren laesst, keine Aussage ist
            : (try? JSONEncoder().encode(station)).map(UserChoiceValue.data)
        note(cloudKey: UserChoiceCatalog.recentStationPrefix + station.id, value: value)
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

    /// A person subscribed (the feed address travels) or unsubscribed (a
    /// tombstone). An import is a person acting too; mechanics (a server
    /// pull, a mirror) never note.
    func noteSubscription(feedURL: String, subscribed: Bool) {
        let feedKey = PodcastSubscriptions.feedKey(feedURL)
        // Subscribing again is the newer statement about the same feed. The
        // record of the older removal goes now, not at the next reconcile:
        // both happening while the sync is off would otherwise leave two
        // statements about one feed with nothing to order them.
        if subscribed {
            var recorded = removalRecords()
            if recorded.removeValue(forKey: feedKey) != nil { saveRemovalRecords(recorded) }
        }
        note(cloudKey: UserChoiceCatalog.subscriptionPrefix + feedKey,
             value: subscribed ? .string(feedURL) : nil)
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
            // For every other family the statement can be rebuilt from local
            // state when the switch goes on. A subscription REMOVAL cannot:
            // the reconcile refuses to derive one, on purpose. So it is
            // recorded here, or it is lost.
            if value == nil, cloudKey.hasPrefix(UserChoiceCatalog.subscriptionPrefix) {
                var recorded = removalRecords()
                recorded[String(cloudKey.dropFirst(UserChoiceCatalog.subscriptionPrefix.count))] = now
                saveRemovalRecords(recorded)
            }
            return
        }
        var blob = cloudBlob()
        let existing = UserChoiceEntry.from(plist: blob[cloudKey])
        if let existing, existing.value == value {
            // Same statement already in the cloud (adoption echo, or a
            // re-select of the same value): align the stamp, write nothing.
            // A fresh "now" here would re-stamp foreign knowledge as new.
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
        // The cap must hold on the PUSH path too. A foregrounded device can
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
        // A reconcile asks the CLOUD, never the mirror. A foreign device may
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
        var manualStationsTouched = false
        var recentsTouched = false
        var hiddenTouched = false
        var premiumTouched = false
        pendingSubscriptionsAdded = []
        pendingSubscriptionsRemoved = []

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
                         manualStationsTouched: &manualStationsTouched,
                         recentsTouched: &recentsTouched,
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
        if recentsTouched {
            rebuildRecentStations(blob: blob)
        }
        // Subscriptions offered in this pass: handed over once, the store
        // follows the feeds in the background and writes the sync history
        // from what really happened (followed, removed, waiting for a
        // login), not from what was offered.
        let subscriptionsAdded = pendingSubscriptionsAdded
        let subscriptionsRemoved = pendingSubscriptionsRemoved
        pendingSubscriptionsAdded = []
        pendingSubscriptionsRemoved = []
        if !subscriptionsAdded.isEmpty || !subscriptionsRemoved.isEmpty {
            subscriptionAdopter?(subscriptionsAdded, subscriptionsRemoved)
        }

        let beforePrune = blob.count
        pruneOverflow(&blob)
        if blobChanged || blob.count != beforePrune {
            saveBlob(blob)
            carrier.flush()
        }
        saveStamps(stamps)
        // A recorded removal that the cloud now carries has been said. Kept
        // any longer it would be re-stated on every reconcile forever.
        let recorded = removalRecords()
        if !recorded.isEmpty {
            var cloudRemovalTimes: [String: Double] = [:]
            for (key, plist) in blob where key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) {
                guard let entry = UserChoiceEntry.from(plist: plist), entry.value == nil else { continue }
                cloudRemovalTimes[String(key.dropFirst(UserChoiceCatalog.subscriptionPrefix.count))] = entry.t
            }
            let settled = SubscriptionRemovalRecord.settled(recorded: recorded,
                                                            cloudRemovalTimes: cloudRemovalTimes)
            if !settled.isEmpty {
                saveRemovalRecords(recorded.filter { !settled.contains($0.key) })
            }
        }

        let adoptedAnything = !adoptedScalarKeys.isEmpty || !adoptedFavorites.isEmpty
            || !removedFavoriteIds.isEmpty || searchesTouched || recentsTouched || hiddenTouched
            || premiumTouched
        if adoptedAnything {
            var keys = adoptedScalarKeys
            if !adoptedFavorites.isEmpty || !removedFavoriteIds.isEmpty { keys.append("radioFavorites") }
            if searchesTouched { keys.append("recentSearches") }
            if recentsTouched { keys.append("radioRecents") }
            if hiddenTouched {
                keys.append("continueHiddenMarkers")
            }
            if premiumTouched { keys.append("premiumClassification") }
            Logger.library.notice("CHOICE sync adopted: \(keys.joined(separator: " "), privacy: .public)")
            isAdopting = true
            // The listening rows recompute on this notification; an adopted
            // station or removal in "Listen Again" is the same class of change.
            if hiddenTouched || recentsTouched {
                NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
            }
            NotificationCenter.default.post(name: .userChoicesAdopted, object: nil,
                                            userInfo: ["keys": keys])
            isAdopting = false
        }
    }

    /// Applies one adopted statement. Returns false when the adoption is
    /// refused (the standby guard). The stamp must then stay untouched so
    /// the entry is re-judged on every reconcile.
    private func apply(_ entry: UserChoiceEntry, forCloudKey key: String,
                       adoptedScalarKeys: inout [String],
                       adoptedFavorites: inout [(station: RadioStation, t: Double)],
                       removedFavoriteIds: inout [String],
                       searchesTouched: inout Bool,
                       manualStationsTouched: inout Bool,
                       recentsTouched: inout Bool,
                       hiddenTouched: inout Bool,
                       premiumTouched: inout Bool) -> Bool {
        // A leftover of the test harness never becomes a person's choice.
        // It is dropped here AND its tombstone travels, so the other
        // device loses it too without anyone touching an account.
        if UserChoiceCatalog.isHarnessSeed(cloudKey: key) {
            dropHarnessSeed(cloudKey: key,
                            removedFavoriteIds: &removedFavoriteIds,
                            recentsTouched: &recentsTouched)
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.recentStationPrefix) {
            recentsTouched = true
            return true
        }
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
        if key.hasPrefix(UserChoiceCatalog.manualStationPrefix) {
            let id = String(key.dropFirst(UserChoiceCatalog.manualStationPrefix.count))
            if case .data(let data)? = entry.value,
               // tragbar, weil eine unlesbare Aussage wie ein Grabstein zaehlt: der Sender geht hier, das andere Geraet schreibt ihn neu
               let station = try? JSONDecoder().decode(RadioStation.self, from: data) {
                RadioStore.addManualAdopted(station, defaults: defaults)
            } else {
                RadioStore.removeManual(id, defaults: defaults)
            }
            manualStationsTouched = true
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.variantPrefix) {
            let variantKey = String(key.dropFirst(UserChoiceCatalog.variantPrefix.count))
            if case .string(let url)? = entry.value {
                RadioStore.setSelectedVariantAdopted(key: variantKey, streamURL: url, defaults: defaults)
            } else {
                RadioStore.setSelectedVariantAdopted(key: variantKey, streamURL: nil, defaults: defaults)
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
        if key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) {
            // A device with a podcast server keeps the server as its truth:
            // refused, and the stamp stays untouched, so the statement is
            // offered again should the server go away.
            guard !hasPodcastServer() else { return false }
            let feedKey = String(key.dropFirst(UserChoiceCatalog.subscriptionPrefix.count))
            if case .string(let feedURL)? = entry.value {
                // Offered to the store, which follows the feed later in the
                // background. NOT stamped here: a stamp means "this device
                // holds that statement", and it does not until the feed
                // loaded. Until then the statement is offered again on every
                // reconcile (the store skips what it already has or is
                // fetching), and a failed feed never turns into a stamp
                // without a value.
                pendingSubscriptionsAdded.append((feedURL, entry.t))
                return false
            }
            pendingSubscriptionsRemoved.append(feedKey)
            return true
        }
        if key.hasPrefix(UserChoiceCatalog.knownServerPrefix) {
            // `<service>|<url>` ⇒ the date it worked. The address is offered
            // under the field on this device; nothing connects until the
            // person signs in here.
            let id = String(key.dropFirst(UserChoiceCatalog.knownServerPrefix.count))
            guard let separator = id.firstIndex(of: "|"),
                  let service = KnownServer.Service(rawValue: String(id[..<separator])) else { return false }
            let url = String(id[id.index(after: separator)...])
            if case .double(let at)? = entry.value {
                KnownServers.remember(url, service: service, now: at, defaults: defaults)
            } else {
                KnownServers.forget(KnownServer(url: url, service: service, lastSuccessAt: 0), defaults: defaults)
            }
            return true
        }
        // Scalar (static or dynamic-prefix) key.
        if key == AppStorageKeys.lastPlayedItemId, case .string(let id)? = entry.value,
           PlayerCoordinator.standbyCountsAsFinished(ListeningStore.mark(id, in: defaults)) {
            // Applied to adoption: a pointer that is finished by
            // local numbers is never adopted. And never stamps, so a later
            // un-finish re-offers it.
            return false
        }
        if let value = entry.value {
            defaults.set(value.plist, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        // The region's merged query names are a derived cache of the OLD
        // region. An adopted state must not query with them (the display
        // name works as fallback until the region is re-chosen).
        if key == AppStorageKeys.radioRegionState {
            defaults.removeObject(forKey: AppStorageKeys.radioRegionQueryNames)
        }
        adoptedScalarKeys.append(key)
        return true
    }

    /// Removes a seeded entry here and lets its tombstone travel. The
    /// station families are the ones a seed reached; the log names what
    /// went, never a value.
    private func dropHarnessSeed(cloudKey key: String,
                                 removedFavoriteIds: inout [String],
                                 recentsTouched: inout Bool) {
        if key.hasPrefix(UserChoiceCatalog.favoritePrefix) {
            removedFavoriteIds.append(String(key.dropFirst(UserChoiceCatalog.favoritePrefix.count)))
        } else if key.hasPrefix(UserChoiceCatalog.recentStationPrefix) {
            let id = String(key.dropFirst(UserChoiceCatalog.recentStationPrefix.count))
            RadioStore.removeRecent(id: id, defaults: defaults)
            recentsTouched = true
        }
        let manual = RadioStore.manualStations(defaults: defaults)
        for station in manual where UserChoiceCatalog.isHarnessSeed(id: station.id) {
            RadioStore.removeManual(station.id, defaults: defaults)
        }
        note(cloudKey: key, value: nil)
        Logger.library.notice("CHOICE seed entry dropped id=\(key, privacy: .public)")
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
        // A seeded station never travels out either: the harness's leftovers
        // stay inside the device that ran it.
        for station in RadioStore.favorites(defaults: defaults)
        where !UserChoiceCatalog.isHarnessSeed(id: station.id) {
            add(UserChoiceCatalog.favoritePrefix + station.id,
                (try? JSONEncoder().encode(station)).map(UserChoiceValue.data))
        }
        // The chosen stream variant of a station, one statement per key.
        for (key, url) in RadioStore.allVariantSelections(defaults: defaults) {
            add(UserChoiceCatalog.variantPrefix + key, .string(url))
        }
        // Stations entered by hand travel element by element, like the
        // favourites (D12 N3).
        for station in RadioStore.manualStations(defaults: defaults)
        where !UserChoiceCatalog.isHarnessSeed(id: station.id) {
            add(UserChoiceCatalog.manualStationPrefix + station.id,
                // tragbar, weil ein Sender, der sich nicht kodieren laesst, keine Aussage ist
                (try? JSONEncoder().encode(station)).map(UserChoiceValue.data))
        }
        // The last-heard stations, stamped with their play moment: the
        // stamp when the play noted, else the ring's own time for stock
        // from before the family (never 0 for a station that has a time).
        let recentTimes = RadioStore.recentTimes(defaults: defaults)
        for station in RadioStore.recents(defaults: defaults)
        where !UserChoiceCatalog.isHarnessSeed(id: station.id) {
            let key = UserChoiceCatalog.recentStationPrefix + station.id
            let stamp = stamps[key] ?? recentTimes[station.id].map { $0 * 1000 }
            // tragbar, weil ein Sender, der sich nicht kodieren laesst, keine Aussage ist
            if let data = try? JSONEncoder().encode(station),
               let entry = UserChoiceMerge.localEntry(value: .data(data), stamp: stamp) {
                out[key] = entry
            }
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
        for server in KnownServers.all(defaults: defaults) {
            add(UserChoiceCatalog.knownServerPrefix + server.id, .double(server.lastSuccessAt))
        }
        // The subscriptions, only once the store has loaded: an unloaded
        // store would read as "unsubscribed everything" and the stamps
        // below would turn every subscription into a tombstone.
        let subscriptions = localSubscriptions()
        for (feedKey, feedURL) in subscriptions ?? [:] {
            add(UserChoiceCatalog.subscriptionPrefix + feedKey, .string(feedURL))
        }
        // Keys the person deliberately CLEARED leave no value. Their stamp is
        // the only trace, and it must travel as a tombstone. This holds for
        // families whose local stock is complete the moment it is read.
        // The subscriptions are NOT such a family: "not in the store" also
        // means "not adopted yet" or "feed failed to load", and a derived
        // tombstone would bury the other device's subscription for the
        // whole account. A subscription tombstone comes from the person's
        // unsubscribe only (`noteSubscription(subscribed: false)`).
        for (key, _) in stamps where out[key] == nil && isTravelingCloudKey(key) {
            if key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) { continue }

            out[key] = UserChoiceEntry(value: nil, t: stamps[key] ?? 0)
        }
        // The RECORDED removals, in place of the derivation refused above. A
        // feed that is subscribed again drops out here, so a re-subscribe made
        // while the sync was off is not undone by its own predecessor.
        let subscribedKeys = Set((subscriptions ?? [:]).keys)
        for (feedKey, t) in SubscriptionRemovalRecord.pending(recorded: removalRecords(),
                                                              subscribedKeys: subscribedKeys) {
            let key = UserChoiceCatalog.subscriptionPrefix + feedKey
            if out[key] == nil { out[key] = UserChoiceEntry(value: nil, t: t) }
        }
        return out
    }

    private func isTravelingCloudKey(_ key: String) -> Bool {
        if UserChoiceCatalog.travelingScalars.contains(key) { return true }
        if UserChoiceCatalog.travelingPrefixes.contains(where: { key.hasPrefix($0) }) { return true }
        return [UserChoiceCatalog.favoritePrefix, UserChoiceCatalog.recentStationPrefix,
                UserChoiceCatalog.manualStationPrefix, UserChoiceCatalog.searchPrefix,
                UserChoiceCatalog.hiddenPrefix, UserChoiceCatalog.premiumMarkPrefix,
                UserChoiceCatalog.feedBlockPrefix, UserChoiceCatalog.knownServerPrefix,
                UserChoiceCatalog.subscriptionPrefix].contains { key.hasPrefix($0) }
    }

    /// The old premium-classification channel as weakest statements (t = 0)
    /// for elements the blob does not carry yet. Read every reconcile. A
    /// device on the old build keeps writing these keys until it updates.
    private func legacyStatements(blobKeys: Set<String>) -> [String: UserChoiceEntry] {
        var out: [String: UserChoiceEntry] = [:]
        func fold(listKey: String, removedKey: String, prefix: String) {
            for feed in carrier.legacyList(forKey: listKey) ?? [] {
                let key = prefix + feed
                guard !blobKeys.contains(key) else { continue }
                out[key] = UserChoiceEntry(value: .bool(true), t: 0)
            }
            for feed in carrier.legacyList(forKey: removedKey) ?? [] {
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
    /// (newest event first, capped). Order is time-derived here, unlike the
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

    /// The last-heard ring from the blob: both devices' plays, newest
    /// first, capped like the local ring, removals gone.
    private func rebuildRecentStations(blob: [String: Any]) {
        var elements: [(station: RadioStation, t: Double)] = []
        for (key, raw) in blob where key.hasPrefix(UserChoiceCatalog.recentStationPrefix) {
            guard let entry = UserChoiceEntry.from(plist: raw),
                  case .data(let data)? = entry.value,
                  // tragbar, weil ein Blob-Eintrag, der kein Sender ist, uebersprungen wird
                  let station = try? JSONDecoder().decode(RadioStation.self, from: data) else { continue }
            elements.append((station, entry.t))
        }
        let merged = UserChoiceMerge.mergedRecents(elements: elements,
                                                   localOrder: RadioStore.recents(defaults: defaults).map(\.id),
                                                   cap: RadioStore.recentsCap)
        RadioStore.replaceRecents(merged.map(\.station),
                                  times: Dictionary(merged.map { ($0.station.id, $0.t / 1000) },
                                                    uniquingKeysWith: { a, _ in a }),
                                  defaults: defaults)
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
        let blob = carrier.loadBlob()
        blobCache = blob
        return blob
    }

    private func saveBlob(_ blob: [String: Any]) {
        blobCache = blob
        carrier.storeBlob(blob)
        // No per-note synchronize: KVS coalesces on its own; the explicit
        // flush runs at start/reconcile, where it pays for itself.
    }

    func localStamps() -> [String: Double] {
        defaults.dictionary(forKey: Self.stampsKey) as? [String: Double] ?? [:]
    }

    private func saveStamps(_ stamps: [String: Double]) {
        defaults.set(stamps, forKey: Self.stampsKey)
    }

    private func removalRecords() -> [String: Double] {
        defaults.dictionary(forKey: Self.removalRecordKey) as? [String: Double] ?? [:]
    }

    private func saveRemovalRecords(_ records: [String: Double]) {
        defaults.set(records, forKey: Self.removalRecordKey)
    }

    /// Serialized blob size. The budget witness for the diagnosis/report.
    func blobBytes() -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: cloudBlob(),
                                             format: .binary, options: 0))?.count ?? 0
    }
}
