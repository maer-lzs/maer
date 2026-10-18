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
    static let shared = AccessFollowers.enrolled(UserChoiceCloudSync(
        carrier: ChoiceCarriers.make(),
        identity: { MaerSyncCarriers.session.identity?.scope },
        serviceAddress: { MaerSyncCarriers.session.access?.baseURL.absoluteString },
        shelf: MaerDatabase.restingShelf))

    /// The blob's key belongs to the key-value carrier; kept here by name
    /// for the witnesses that read the fake store directly.
    static let blobKey = KeyValueChoiceCarrier.blobKey
    static let stampsKey = "userChoiceStamps"
    /// Unsubscribes made while the sync was off. See `SubscriptionRemovalRecord`.
    static let removalRecordKey = "userChoiceSubscriptionRemovals"

    private let defaults: UserDefaults
    /// The transport. It holds and delivers the blob; every rule of the
    /// merge stays here.
    private var carrier: any ChoiceCarrier
    private var generation = CarrierGeneration()
    private let syncEnabled: () -> Bool
    /// Event clock in ms. Injectable so merge ordering is deterministic in
    /// tests.
    private let now: () -> Double
    /// An item id in the form the music server answers to (Navidrome's new
    /// ids); the identity where the rule does not hold. Injectable so two
    /// devices on different builds can share one document in a witness.
    private let itemIdMap: (String) -> String
    /// The account signed in now (`MaerSyncIdentity.scope`), nil when none
    /// is, and where the choices of another account rest. Only the app's
    /// runner has them; a witness hands in its own, every other one keeps
    /// no owner and never touches a shelf.
    private let identity: () -> String?
    /// The address of the sync service signed in now; it stays known across
    /// a switch.
    private let serviceAddress: () -> String?
    /// The family's way through the shelf (`ShelfFollower`); nil without a
    /// shelf, which is the case of every witness that does not hand one in.
    private let follower: ShelfFollower?
    /// The stamps, in rows with their owner in the key: the account whose
    /// choices lie on the device (`""` before any). Another account's stamps
    /// stay under its own name in the rows and are never read for these
    /// choices, so no account dates its choices with another's moments, not
    /// even after a run that died in the middle of a hand-over.
    private let stampRows: ChoiceStampRows
    private var stampOwner: String
    /// A round waits while the stamps could not be read: without them every
    /// choice here would date from nothing and the cloud would win over it.
    private var roundWaitsForStamps = false
    /// Whether statements that carry the music server's ids may travel
    /// (`SubsonicProvider.idFormSettled`).
    private let idFormSettled: () -> Bool
    private var didStart = false
    /// True while adoption results are being applied/announced. A note that
    /// fires as an echo of adoption must align stamps, never re-stamp "now".
    private(set) var isAdopting = false
    /// The local subscriptions as the family sees them: feed key ⇒ feed
    /// address, or nil while the store has not loaded (then the family says
    /// nothing, and above all writes no tombstones).
    var localSubscriptions: () -> [String: String]? = { nil }
    /// Applies adopted subscription statements: feeds to follow (with the
    /// moment of subscribing) and feed keys to leave. Set by the store.
    var subscriptionAdopter: ((_ added: [(feedURL: String, t: Double)], _ removed: [String]) -> Void)?
    /// Hands the subscriptions to an account (`PodcastSubscriptions.follow`),
    /// false while it cannot. Set by the store; the choices follow only
    /// after the subscriptions did.
    var subscriptionsFollow: (_ scope: String, _ previous: String?) -> Bool = { _, _ in true }
    /// The one door of the sources, taken when an adoption changed a tab or
    /// source switch (`UserChoiceCatalog.touchesSources`), as a change here
    /// takes it: the clients are built and the sources signal goes out.
    var sourcesAdopted: @MainActor () -> Void = { AppSession.shared.reconfigureSources() }
    /// Collected during one reconcile, handed to the adopter once at its end.
    private var pendingSubscriptionsAdded: [(feedURL: String, t: Double)] = []
    private var pendingSubscriptionsRemoved: [String] = []

    init(defaults: UserDefaults = .standard,
         cloud: any UserChoiceCloudStore = CloudKeyValue.store,
         carrier: (any ChoiceCarrier)? = nil,
         syncEnabled: @escaping () -> Bool = { AppStorageKeys.syncAcrossDevicesEnabled },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
         itemIdMap: @escaping (String) -> String = { SubsonicProvider.canonicalItemId($0) },
         identity: @escaping () -> String? = { nil },
         serviceAddress: @escaping () -> String? = { nil },
         shelf: RestingShelf? = nil,
         stamps: ChoiceStampRows? = nil,
         idFormSettled: @escaping () -> Bool = { SubsonicProvider.idFormSettled() }) {
        self.defaults = defaults
        self.itemIdMap = itemIdMap
        self.identity = identity
        self.serviceAddress = serviceAddress
        self.follower = shelf.map { ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "CHOICE") }
        let stampRows = stamps ?? ChoiceStampRows.matching(defaults)
        self.stampRows = stampRows
        // bearable, because an unreadable holding names no owner yet; the hand-over reads it again and holds the round while it cannot
        let holder = (try? shelf?.holding(of: Self.shelfFamily))??.owner ?? ""
        self.stampOwner = holder
        // The blob of the stamps moved under its own name; it dates the
        // choices that lie here, so it goes to their holder.
        if stampRows.holds(ChoiceStampRows.legacyOwner) {
            let moved = stampRows.rows(ChoiceStampRows.legacyOwner)
            stampRows.set(holder, moved.merging(stampRows.rows(holder)) { _, rows in rows })
            stampRows.set(ChoiceStampRows.legacyOwner, [:])
        }
        self.idFormSettled = idFormSettled
        // A carrier handed in wins. Else the store given (a test's dictionary
        // fake, or the door) becomes the key-value carrier, so every witness
        // that reads its fake directly keeps seeing the same blob.
        self.carrier = carrier ?? KeyValueChoiceCarrier(store: cloud)
        self.syncEnabled = syncEnabled
        self.now = now
    }

    #if DEBUG
    /// The unit-test HOST must not touch the real KVS: other suites drive
    /// production write paths (sorts, rates, favorites) through the shared
    /// instance, and their notes would accumulate in the simulator's store
    /// across runs. Every later host start would adopt that junk back
    /// (test-poisons-real-store class). Injected test instances carry their
    /// own fake cloud and stay fully live.
    private var sharedMustStaySilent: Bool {
        self === Self.shared && TestProcess.isUnderTest
    }
    #else
    private var sharedMustStaySilent: Bool { false }
    #endif

    func start() {
        if sharedMustStaySilent { return }
        forgetRetired()
        guard syncEnabled() else { return }
        guard !didStart else { reconcile(); return }
        didStart = true
        startCarrier(by: "start")
        NotificationCenter.default.addObserver(
            self, selector: #selector(knownServersChanged),
            name: KnownServers.didChange, object: nil)
        reconcile()
    }

    /// The carrier delivers: it flushes once on start and wakes the
    /// reconcile whenever the far side moved.
    private func startCarrier(by caller: String) {
        Logger.library.notice("CHOICE carrier=\(self.carrier.name, privacy: .public) by=\(caller, privacy: .public)")
        carrier.start(onChange: generation.guarded({ [weak self] in self?.generation }) { [weak self] in
            self?.reconcile()
        })
    }

    /// The carrier the access of this moment asks for, when it travels
    /// another way than the held one; see `PodcastCloudSync.follow`. The
    /// subscriptions and the known servers are choices, so they arrive with
    /// the first reconcile over the new carrier.
    func follow(_ next: @autoclosure () -> any ChoiceCarrier, signedIn: Bool, identityChanged: Bool = false, by caller: String) {
        guard CarrierWay.mustChange(holdsService: CarrierWay.isService(carrierName: carrier.name),
                                    signedIn: signedIn, identityChanged: identityChanged) else { return }
        carrier.stop()
        CarrierRefreshers.unregister(carrier)
        carrier = next()
        generation.advance()
        guard didStart else { return }
        startCarrier(by: caller)
        reconcile()
    }

    /// A retired choice goes from this device, whether it syncs or not.
    /// Removed without a note: its feature is gone, so there is no choice to
    /// tell the other devices about.
    func forgetRetired() {
        let local = defaults.dictionaryRepresentation().keys.filter(UserChoiceCatalog.isRetired)
        for key in local { defaults.removeObject(forKey: key) }
        if !local.isEmpty {
            Logger.library.notice("CHOICE retired local=\(local.count)")
        }
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
        let read = UserChoiceValue.read(plist: value)
        // A value of a kind the choices cannot carry is no clear: noted as
        // nil it would travel as a tombstone and clear the other devices.
        guard !read.unknown else {
            Logger.library.error("CHOICE local value of an unknown kind not noted key=\(key, privacy: .public)")
            return
        }
        note(cloudKey: key, value: read.value)
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
            // bearable, because a station that does not encode is no statement
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
            // bearable, because a station that does not encode is no statement
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
        // A note right after a switch (the known servers of the sign-in)
        // hands the choices over first, or it would stamp the holder's.
        guard followsTheAccount() else { return }
        var stamps = localStamps()
        let now = now()
        /// The statement kept for a later round: its event time survives,
        /// and a subscription removal is recorded.
        func keepForLater() {
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
        }
        guard syncEnabled() else {
            keepForLater()
            return
        }
        var blob = cloudBlob()
        let existing = UserChoiceEntry.from(plist: blob[cloudKey])
        // An entry of an unknown kind is never "the same statement", also
        // not as a clear: the newer local statement replaces it.
        if let existing, !existing.unknownKind, existing.value == value {
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
        // A statement that names an item of the music server waits for the
        // form like a round does, behind the echo and the adoption, which
        // stamp nothing: it is stamped here and travels with the first round
        // after the wait, rekeyed. Written now it would stand in the old
        // form, and nothing folds it later. The form is asked only when the
        // statement names such an item, so no other statement starts the
        // wait's clock.
        if Self.namesServerMusic(cloudKey: cloudKey, value: value), !idFormSettled() {
            Logger.library.notice("CHOICE note held: the music server's id form is not settled yet")
            keepForLater()
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

    // MARK: - The owner of the choices

    private static let shelfFamily = "choices"

    /// What rests for an account: the stored value of every key the family
    /// keeps (`restingKeys`) as property-list data, the recorded removals
    /// included. The stamps rest in their rows under the account's name
    /// (`stampRows`); a rest laid by an earlier build still carries them as
    /// a key, and they go to the rows when it comes back. Without the stamps
    /// the next round would derive the holder's keys as removals into the
    /// new account's document.
    nonisolated struct Resting: Codable, Equatable {
        var values: [String: Data]
    }

    /// Every key the family keeps on this device: the travelling scalars,
    /// the keys of the travelling families, the element-wise stores and the
    /// bookkeeping. The subscriptions are rows and follow on their own.
    func restingKeys() -> [String] {
        let stores = [RadioStore.favoritesKey, RadioStore.manualKey, RadioStore.recentsKey,
                      RadioStore.recentTimesKey, RadioStore.variantSelectionKey, RecentSearches.storageKey,
                      AppStorageKeys.continueHiddenMarkers, AppStorageKeys.premiumMarkedFeeds,
                      AppStorageKeys.blockedFeedKeys, KnownServers.storeKey,
                      Self.removalRecordKey]
        let families = defaults.dictionaryRepresentation().keys.filter { key in
            UserChoiceCatalog.travelingPrefixes.contains { key.hasPrefix($0) }
        }
        return Array(Set(UserChoiceCatalog.travelingScalars + stores + families)).sorted()
    }

    /// The choices as they lie, for the shelf.
    func restingChoices() throws -> Resting {
        var values: [String: Data] = [:]
        for key in restingKeys() {
            guard let raw = defaults.object(forKey: key) else { continue }
            values[key] = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
        }
        return Resting(values: values)
    }

    /// Whether the choices belong to the account signed in now, handing
    /// them over first by the shelf's one rule (`RestingShelf.handOver`).
    /// False while they cannot be handed over; nothing then is noted or
    /// sent, since it would carry the holder's choices to the account.
    private func followsTheAccount(previous: String? = nil) -> Bool {
        guard let follower, let scope = identity() else { return true }
        if scope != follower.handedTo {
            // The document read before is the one of the account before: a
            // note must not compare against it, nor write it on.
            blobCache = nil
            // The subscriptions are rows of their store and read by this
            // family: they move first, or the round would read the holder's.
            guard subscriptionsFollow(scope, previous) else { return false }
        }
        guard let step = follower.follow(
            to: scope, previous: previous, unread: false, landing: .now,
            current: { try restingChoices() },
            replace: { rest, owner, _ in
                // The stamps of the owner coming in are its own rows; set
                // before the choices land, so an echo of the adoption aligns
                // against them.
                stampOwner = owner
                try replaceChoices(with: rest)
            }) else { return false }
        if step == .first, stampOwner != scope {
            // The first account takes the stock that is here, its stamps too.
            let here = stampRows.rows(stampOwner)
            stampRows.set(scope, here.merging(stampRows.rows(scope)) { _, own in own })
            stampRows.set(stampOwner, [:])
        }
        if step != .unread { stampOwner = scope }
        if step != .kept {
            Logger.library.notice("CHOICE owner \(String(describing: step), privacy: .public) keys=\(self.restingKeys().count)")
        }
        return true
    }

    /// The choices of the new owner replace the ones here, without a note:
    /// every key of the family leaves, the rest of the owner is written (none:
    /// every choice at its default). The address of the sync service just
    /// signed in stays known (plan `e9d802f5`), no other of the holder's.
    private func replaceChoices(with incoming: Resting?) throws {
        let service = serviceAddress()
        var restored: [(String, Any)] = []
        for (key, data) in incoming?.values ?? [:] {
            let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
            if key == Self.stampsKey {
                // A rest an earlier build laid: its stamps go to the rows of
                // the owner coming in, under any its rows already hold.
                let laid = raw as? [String: Double] ?? [:]
                stampRows.set(stampOwner, laid.merging(stampRows.rows(stampOwner)) { _, own in own })
                continue
            }
            restored.append((key, raw))
        }
        // Every key that leaves is a change too: the announcement names the
        // keys before and after, or a surface of a key that left keeps it.
        let before = restingKeys()
        for key in before { defaults.removeObject(forKey: key) }
        for (key, raw) in restored { defaults.set(raw, forKey: key) }
        if let service {
            KnownServers.remember(service, service: .maerSync, defaults: defaults)
        }
        let keys = Array(Set(before).union(restingKeys())).sorted()
        isAdopting = true
        NotificationCenter.default.post(name: PlayedTail.didChange, object: nil)
        NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
        NotificationCenter.default.post(name: .userChoicesAdopted, object: nil, userInfo: ["keys": keys])
        if UserChoiceCatalog.touchesSources(keys) { sourcesAdopted() }
        isAdopting = false
    }

    // MARK: - Reconcile

    func reconcile() {
        if sharedMustStaySilent { return }
        guard syncEnabled() else { return }
        // Stamps nobody could read are unknown, not empty: the round waits
        // for them and runs once they are read.
        guard !stampRows.unread else {
            if !roundWaitsForStamps {
                roundWaitsForStamps = true
                stampRows.whenRead { [weak self] in
                    self?.roundWaitsForStamps = false
                    self?.reconcile()
                }
            }
            Logger.library.notice("CHOICE round held: the stamps are not read")
            return
        }
        // Another account than the choices' owner: its choices replace the
        // owner's first, or the round would carry them to it.
        guard followsTheAccount() else {
            Logger.library.notice("CHOICE round held: the choices wait for their owner")
            return
        }
        let signpost = PerfSignpost.syncRound(.userChoices, .local)
        defer { signpost.end() }
        // A reconcile asks the CLOUD, never the mirror. A foreign device may
        // have written since the last read (the mirror only spares the notes).
        blobCache = nil
        // Choices keyed by the music server's ids wait while the form of
        // those ids is undecided (a new address before its first answer),
        // or the old and the new form of one item would stand side by side.
        // The wait ends (`idFormSettled`); it is asked only when such ids
        // are here, so a round without them starts no clock.
        if holdsServerMusicIds(), !idFormSettled() {
            Logger.library.notice("CHOICE round held: the music server's id form is not settled yet")
            return
        }
        let map = itemIdMap
        rekeyLocalChoices(map)
        var blob = cloudBlob()
        var stamps = localStamps()
        let localEntries = collectLocalEntries(stamps: stamps)
        // Counted as found, before the merge: whether a subscription is in
        // the document at all, whether this device follows it, and what the
        // merge decides for each one it does not follow.
        let count = UserChoiceMerge.subscriptionCount(local: localSubscriptions().map { Set($0.keys) },
                                                      localEntries: localEntries, blob: blob)
        Logger.library.notice("CHOICE subscriptions local=\(count.local.map(String.init) ?? "unknown", privacy: .public) document=\(count.document) removed=\(count.removed) unheld=\(count.unheld.map(String.init) ?? "unknown", privacy: .public) adopt=\(count.adopt) push=\(count.push) stampOnly=\(count.stampOnly) none=\(count.none)")

        var blobChanged = false
        // Retired choices leave the document and the stamps before anything
        // is decided, so none of them is adopted, pushed or tombstoned.
        let retired = blob.keys.filter(UserChoiceCatalog.isRetired)
        for key in retired { blob.removeValue(forKey: key) }
        if !retired.isEmpty {
            blobChanged = true
            Logger.library.notice("CHOICE retired document=\(retired.count)")
        }
        for key in stamps.keys where UserChoiceCatalog.isRetired(key) { stamps.removeValue(forKey: key) }
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

        // The document read with its item ids in the form this device keeps;
        // an old key stays in it untouched (see `NavidromeRekey.foldedChoices`).
        let cloud = NavidromeRekey.foldedChoices(blob.compactMapValues(UserChoiceEntry.from(plist:)), map)
        let allKeys = Set(cloud.keys).union(localEntries.keys)
        for key in allKeys {
            let cloudEntry = cloud[key]
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
                    // A statement the document carries only under an older
                    // item id (folded above) gets its entry under this one.
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
            // Said, because a missing adopter drops the offer without a trace.
            Logger.library.notice("CHOICE subscriptions offered=\(subscriptionsAdded.count) left=\(subscriptionsRemoved.count) adopter=\(self.subscriptionAdopter == nil ? "none" : "set", privacy: .public)")
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
                guard let entry = UserChoiceEntry.from(plist: plist), entry.value == nil,
                      !entry.unknownKind else { continue }
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
            if keys.contains(where: { $0 == PlayedTail.generalKey || $0.hasPrefix(PlayedTail.prefix) }) {
                NotificationCenter.default.post(name: PlayedTail.didChange, object: nil)
            }
            Logger.library.notice("CHOICE sync adopted: \(keys.joined(separator: " "), privacy: .public)")
            isAdopting = true
            // The listening rows recompute on this notification; an adopted
            // station or removal in "Listen Again" is the same class of change.
            if hiddenTouched || recentsTouched {
                NotificationCenter.default.post(name: .continueHiddenChanged, object: nil)
            }
            NotificationCenter.default.post(name: .userChoicesAdopted, object: nil,
                                            userInfo: ["keys": keys])
            if UserChoiceCatalog.touchesSources(keys) { sourcesAdopted() }
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
               // bearable, because an unreadable statement counts as a tombstone: the station goes here, the other device writes it again
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
            // A device with a podcast server applies the family too and
            // hands the change on to its server through the next gpodder
            // round; the family and the server say the same thing. The
            // refusal that stood here made the two drift: an unsubscribe on
            // the device without a server reached this one and was ignored,
            // so gpodder kept the feed while the other device had left it.
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
        // A local value of a kind the choices cannot carry makes no entry:
        // read as nil it would go out as a tombstone and clear the key on
        // every other device.
        var unknownKinds: Set<String> = []
        func addRead(_ key: String, _ raw: Any?) {
            let read = UserChoiceValue.read(plist: raw)
            if read.unknown { unknownKinds.insert(key) } else { add(key, read.value) }
        }
        for key in UserChoiceCatalog.travelingScalars {
            addRead(key, defaults.object(forKey: key))
        }
        for (key, raw) in defaults.dictionaryRepresentation() {
            guard UserChoiceCatalog.travelingPrefixes.contains(where: { key.hasPrefix($0) })
            else { continue }
            addRead(key, raw)
        }
        if !unknownKinds.isEmpty {
            Logger.library.error("CHOICE local values of an unknown kind kept out count=\(unknownKinds.count)")
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
        // favourites.
        for station in RadioStore.manualStations(defaults: defaults)
        where !UserChoiceCatalog.isHarnessSeed(id: station.id) {
            add(UserChoiceCatalog.manualStationPrefix + station.id,
                // bearable, because a station that does not encode is no statement
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
            // bearable, because a station that does not encode is no statement
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
        // A key that holds a value of an unknown kind is not cleared either.
        for (key, _) in stamps where out[key] == nil && isTravelingCloudKey(key) && !unknownKinds.contains(key) {
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
                  // bearable, because a blob entry that is no station is skipped
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
        let map = itemIdMap
        for key in UserChoiceMerge.overflowKeys(
            entries: rates.map { (key: $0.0, t: $0.1) },
            cap: UserChoiceCatalog.playbackRateCap,
            statement: { NavidromeRekey.choiceKey($0, map) }) {
            blob.removeValue(forKey: key)
        }
    }

    // MARK: - Navidrome's new ids

    /// Whether a choice here names an item of the music server, in the set
    /// `rekeyLocalChoices` moves: the pointer to the last item, and the
    /// item-keyed choices with their stamps and hidden markers.
    func holdsServerMusicIds() -> Bool {
        if let last = defaults.string(forKey: AppStorageKeys.lastPlayedItemId), SubsonicProvider.owns(itemId: last) { return true }
        let held = heldItemChoices(stamps: localStamps(), markers: ContinueHiddenStore.markers(defaults: defaults))
        return held.keys.contains { NavidromeRekey.choiceItemId($0).map(SubsonicProvider.owns(itemId:)) == true }
    }

    /// Whether a statement names an item of the music server: by its key,
    /// or as the pointer to the last item by its value.
    private static func namesServerMusic(cloudKey: String, value: UserChoiceValue?) -> Bool {
        if NavidromeRekey.choiceItemId(cloudKey).map(SubsonicProvider.owns(itemId:)) == true { return true }
        guard NavidromeRekey.itemValuedChoices.contains(cloudKey), case .string(let id)? = value else { return false }
        return SubsonicProvider.owns(itemId: id)
    }

    /// The item-keyed choices this device holds, by key: the values, the
    /// hidden markers, and stamps of removed ones. What `rekeyLocalChoices`
    /// moves, and what waits for the form.
    private func heldItemChoices(stamps: [String: Double], markers: [String: Double]) -> [String: UserChoiceEntry] {
        let prefixes = NavidromeRekey.itemKeyedChoicePrefixes
        func isItemKeyed(_ key: String) -> Bool { prefixes.contains { key.hasPrefix($0) } }
        var held: [String: UserChoiceEntry] = [:]
        var unknownKinds: Set<String> = []
        for (key, raw) in defaults.dictionaryRepresentation()
        where isItemKeyed(key) && !key.hasPrefix(UserChoiceCatalog.hiddenPrefix) {
            // A value of an unknown kind is not held as a clear: it stays
            // where it is, under its key, and is not moved.
            let read = UserChoiceValue.read(plist: raw)
            guard !read.unknown else {
                unknownKinds.insert(key)
                Logger.library.error("CHOICE item value of an unknown kind not moved key=\(key, privacy: .public)")
                continue
            }
            held[key] = UserChoiceEntry(value: read.value, t: stamps[key] ?? 0)
        }
        for (id, marker) in markers {
            let key = UserChoiceCatalog.hiddenPrefix + id
            held[key] = UserChoiceEntry(value: .double(marker), t: stamps[key] ?? 0)
        }
        for (key, t) in stamps where held[key] == nil && isItemKeyed(key) && !unknownKinds.contains(key) {
            held[key] = UserChoiceEntry(value: nil, t: t)
        }
        return held
    }

    /// This device's own choices with item ids in the form `map` gives:
    /// the item-keyed families move with their stamps, the pointer to the
    /// last item takes the new id. Mechanics, so nothing is noted and no
    /// stamp is new; where an old and a new key meet, the later statement
    /// stays. Returns how many choices changed and how many it looked at.
    @discardableResult
    func rekeyLocalChoices(_ map: (String) -> String) -> (changed: Int, total: Int) {
        var changed = 0
        let last = defaults.string(forKey: AppStorageKeys.lastPlayedItemId)
        if let last, map(last) != last {
            defaults.set(map(last), forKey: AppStorageKeys.lastPlayedItemId)
            changed += 1
        }
        var stamps = localStamps()
        var markers = ContinueHiddenStore.markers(defaults: defaults)
        let held = heldItemChoices(stamps: stamps, markers: markers)
        let moved = held.keys.filter { NavidromeRekey.choiceKey($0, map) != $0 }
        let total = held.count + (last == nil ? 0 : 1)
        guard !moved.isEmpty else { return (changed, total) }
        let folded = NavidromeRekey.foldedChoices(held, map)
        func write(_ key: String, _ value: UserChoiceValue?) {
            if key.hasPrefix(UserChoiceCatalog.hiddenPrefix) {
                let id = String(key.dropFirst(UserChoiceCatalog.hiddenPrefix.count))
                if case .double(let marker)? = value { markers[id] = marker } else { markers.removeValue(forKey: id) }
            } else if let value {
                defaults.set(value.plist, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        for key in moved {
            write(key, nil)
            stamps.removeValue(forKey: key)
        }
        for key in Set(moved.map { NavidromeRekey.choiceKey($0, map) }) {
            guard let entry = folded[key] else { continue }
            write(key, entry.value)
            if entry.t > 0 { stamps[key] = entry.t } else { stamps.removeValue(forKey: key) }
        }
        defaults.set(markers, forKey: AppStorageKeys.continueHiddenMarkers)
        saveStamps(stamps)
        return (changed + moved.count, total)
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

    /// The stamps of the choices that lie here, from the rows of their
    /// owner. The rows write only the stamps that changed; before, every
    /// note wrote the whole dictionary into the defaults.
    func localStamps() -> [String: Double] {
        stampRows.rows(stampOwner)
    }

    /// Test seam: the stamps of the choices that lie here, as a witness
    /// hands them in.
    func _seedStampsForWitness(_ stamps: [String: Double]) {
        saveStamps(stamps)
    }

    private func saveStamps(_ stamps: [String: Double]) {
        stampRows.set(stampOwner, stamps)
    }

    private func removalRecords() -> [String: Double] {
        defaults.dictionary(forKey: Self.removalRecordKey) as? [String: Double] ?? [:]
    }

    private func saveRemovalRecords(_ records: [String: Double]) {
        defaults.set(records, forKey: Self.removalRecordKey)
    }

    /// Serialized blob size, for the witness of the budget; no surface
    /// reads it.
    func blobBytes() -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: cloudBlob(),
                                             format: .binary, options: 0))?.count ?? 0
    }
}

extension UserChoiceCloudSync: AccessFollower {
    var followerName: String { "choices" }

    /// The stock follows a change of account at the moment of the change,
    /// with the sync switch off as well (`AccessFollower.followOwner`).
    func followOwner(previous: String?) {
        _ = followsTheAccount(previous: previous)
    }

    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        follow(ChoiceCarriers.make(), signedIn: signedIn, identityChanged: identityChanged, by: caller)
    }
}
