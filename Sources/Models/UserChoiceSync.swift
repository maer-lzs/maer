// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Sync class of a persisted user choice. Every stored key declares one at
/// birth. The catalog below is the one place that knows, and a source-scan
/// test keeps it complete (a new key without a class turns the suite red).
nonisolated enum UserChoiceClass {
    /// A judgement about CONTENT. Travels across the person's devices.
    case travels
    /// A deliberate per-device choice (ergonomics, permissions, accounts).
    case device
    /// Machine state, credentials, queues, caches. No user judgement at all.
    case machine
}

/// The classification catalog: every persisted key of the key-bearing files
/// (`AppStorageKeys`, `RadioStore`, `RecentSearches`) with its sync class.
/// Membership of the travelling family is a decision, not an inference.
/// The `travels` rows mirror the decided inventory exactly.
nonisolated enum UserChoiceCatalog {

    /// Static keys → class. Literals are the STORED key strings.
    static let statics: [String: UserChoiceClass] = [
        // Travels: sort/filter choices (one mechanic, all media tabs)
        "librarySortOption": .travels,
        "librarySortAscending": .travels,
        "libraryFilterOption": .travels,
        "podcastSortOption": .travels,
        "podcastFilterOption": .travels,
        "musicSortOption": .travels,
        // Travels: browse choices
        "radioGenreCountryCodes": .travels,
        "radioChosenCountryCode": .travels,
        "radioChosenCountryName": .travels,
        "radioRegionCountryCode": .travels,
        "radioRegionCountryName": .travels,
        "radioRegionState": .travels,
        // Travels: standby pointer (a POINTER, never a second position
        //   channel; adoption never auto-plays and never adopts a finished id)
        "lastPlayedItemId": .travels,
        // Travels, element-wise (each element is its own statement)
        "radioFavorites": .travels,
        "recentSearches": .travels,
        "continueHiddenMarkers": .travels,
        "premiumMarkedFeeds": .travels,
        "blockedFeedKeys": .travels,
        // The register of server ADDRESSES that once worked: address,
        // service and date, never a credential (decided). The second device
        // offers them under its address fields and signs in itself.
        "knownServers": .travels,
        // The podcast subscriptions, one statement per feed. Decided: a
        // device without a podcast server follows the account's list; a
        // device with a server keeps the server as its truth and never
        // applies these, but still notes its own changes for the others.
        "podcastSubscriptions": .travels,

        // What the person CHOSE travels: one account is one person; only
        // downloads and device technique stay behind.
        // Playback preferences are a person's habits, not a device's.
        "skipInterval": .travels,
        "musicSkipInterval": .travels,
        "defaultPlaybackRate": .travels,
        "smartRewind": .travels,
        "autoPlayNextInSeries": .travels,
        // The duration the sleep timer was last started with. It belongs to
        // the situation a device is used in, not to the person: half an hour
        // on the bedside phone says nothing about the tablet in the kitchen.
        // The travelling set is a decided list, and this is not on it.
        "sleepTimerLastMinutes": .device,
        // Which shows a person does not want to see is that person's
        // choice; the kept browsed episodes behind it stay local, so the
        // other device applies the choice to what IT heard.
        "coListenedHidden": .travels,
        // The card and the import ticks describe this device's state.
        "nextStepsDismissed": .device,
        "foreignImportsDone": .device,
        // Appearance is a person's choice, not a device's.
        "appearanceOverride": .travels,
        "bottomBarAccent": .travels,
        // Which tabs a person wants is the same on both devices.
        "audiobooksTabEnabled": .travels,
        "podcastsTabEnabled": .travels,
        "musicTabEnabled": .travels,
        "radioTabEnabled": .travels,
        // Which sources a person allows travels; the CREDENTIALS behind
        // them stay per device (keychain, machine class), so a device
        // without an account simply has nothing to ask.
        "radioEnabled": .travels,
        "subsonicEnabled": .travels,
        "jellyfinEnabled": .travels,
        "rssEnabled": .travels,
        "pinchflatEnabled": .travels,
        "absPodcastsEnabled": .travels,
        "absAudiobooksEnabled": .travels,
        "gpodderEnabled": .travels,
        "gpodderSyncsPremiumFeeds": .travels,
        // Whether this device runs without a server is its own state.
        "serverlessMode": .device,
        // What a person allows the app to ask the net for, and in which
        // languages: a stance, not a device property.
        "homeRecommendations": .travels,
        "suggestionLanguages": .travels,
        "appleCatalogEnabled": .travels,
        "radioLogoChainEnabled": .travels,
        "musicArtistImagesOnline": .travels,
        "musicLyricsOnlineLookup": .travels,
        "musicHighResCovers": .travels,
        "librivoxRowsEnabled": .travels,
        "archivePopularEnabled": .travels,
        "jamendoRowEnabled": .travels,
        "freeClassicalEnabled": .travels,
        "netlabelsRowEnabled": .travels,
        "shellacRowsEnabled": .travels,
        "freeCatalogsMasterEnabled": .travels,
        "freeAudiobooksEnabled": .travels,
        // The two-question rebuild (source allowed x row visible): both
        // halves are choices and travel with the rest.
        "gutenbergSourceEnabled": .travels,
        "podcastIndexSourceEnabled": .travels,
        "feedArtworkSourceEnabled": .travels,
        "rowHomeDiscoverMusicVisible": .travels,
        "rowHomeRecentlyAddedVisible": .travels,
        "rowBooksRecentVisible": .travels,
        "jamendoRowVisible": .travels,
        "rowPodcastsRadioPlaysVisible": .travels,
        "rowPodcastsRecommendedVisible": .travels,
        "rowRadioCatalogVisible": .travels,
        // What stays with the device, each for a stated reason: the
        // cellular warning belongs to THIS device's connection, drive mode
        // to the car it pairs with, the sync switch is the switch that
        // decides travelling itself (it can never travel, or one device
        // would switch off the other), the notification permission is
        // granted per device, the selected tab is a window state, and the
        // feeds needing a sign-in describe what is missing HERE.
        "warnCellularDownload": .device,
        "driveModeCarRouteUID": .device,
        "driveModeCarRouteName": .device,
        "driveModeAutoStart": .device,
        "podcastICloudSync": .device,
        // The SWITCH is the person's intent and travels; the iOS
        // permission behind it belongs to the device and is asked for
        // there (decided 07.09.2026). A device that cannot notify says so
        // at the switch instead of sending nothing.
        "podcastNewEpisodeNotifications": .travels,
        // The value for all shows travels like the per-show value it
        // stands behind.
        "podcastInboxModeAll": .travels,
        // Automatic downloads stay on the device that downloads (decided
        // 06.09.2026), for all shows as for each show: whether they run and
        // how many they keep. The direction is how the person listens and
        // travels (decided 27.09.2026). The one value of the builds before
        // is only read. Named here so it is read, not assumed.
        "podcastAutoDownloadModeAll": .device,
        "podcastAutoDownloadSinceAll": .device,
        "podcastAutoDownloadOnAll": .device,
        "podcastAutoDownloadKeepAll": .device,
        "podcastAutoDownloadDirectionAll": .travels,
        "playedTailSeconds": .travels,
        "podcastAutoDownloadedIds": .machine,
        "lastSelectedTab": .device,
        "podcastAutoSaveOnPlay": .travels,
        "podcastSubscribeToServer": .travels,
        "podcastFeedsNeedingSignIn": .device,
        // The free twin's search, the No to its offer and the paid address
        // left for it stay here: each device asks its own directory, answers
        // its own question, and the paid address carries a token.
        "podcastFreeTwinSearched": .device,
        "podcastFreeTwinDeclined": .device,
        "podcastPaidTwin": .device,
        // Refused refreshes are measured per device: one device's
        // expired link says nothing about another's.
        "podcastFeedRefusals": .device,
        // Stations a person entered by hand travel element by element
        // (`radioManual.<id>`), like the favourites: the list itself is
        // never a scalar, so the KEY stays out of the travelling scalars
        // while its CONTENT travels. The chosen stream variant of a
        // station travels the same way (`radioVariant.<key>`).
        "radioManualStations": .travels,
        "radioVariantSelection": .travels,

        // Machine: credentials/accounts
        "podcastIndexKey": .machine,
        "podcastIndexSecret": .machine,
        "gpodderServerURL": .machine,
        "gpodderUsername": .machine,
        "subsonicServerURL": .machine,
        "subsonicUsername": .machine,
        "jellyfinServerURL": .machine,
        "jellyfinUsername": .machine,
        "jellyfinUserId": .machine,
        "jellyfinDeviceId": .machine,
        "jamendoClientId": .machine,
        "maerSyncURL": .machine,
        "maerSyncOwner": .machine,
        // Machine: sync/queue state
        "pendingBookmarkOps": .machine,
        "absPendingPlayedWrites": .machine,
        "gpodderEpisodeSince": .machine,
        "gpodderLastEpisodePush": .machine,
        "gpodderLastSyncedFeeds": .machine,
        "gpodderPendingRemoveLocal": .machine,
        "gpodderPendingRemoveServer": .machine,
        "gpodderDeviceRegisteredFor": .machine,
        "gpodderUserRemovedFeeds": .machine,
        "cloudQuotaViolationAt": .machine,
        "pendingDownloadDestinations": .machine,
        // Machine: migration/repair markers
        "listenLogBackfilled": .machine,
        // Machine: setup state and derived caches
        "selectedLibraryId": .machine,
        "subsonicContentType": .machine,
        "subsonicServesMusic": .machine,
        "subsonicServesAudiobooks": .machine,
        "subsonicLibraries": .machine,
        "subsonicLibraryAssignment": .machine,
        // The books library this server reported, measured per device and
        // never chosen, so it stays home like the other derived caches.
        "jellyfinBooksViewId": .machine,
        "librivoxImportLibraryId": .machine,
        "librivoxImportFolderId": .machine,
        "pinchflatMirroredFeedKeys": .machine,
        "radioRegionQueryNames": .machine,
        "radioNationalCountryCode": .machine,
        "radioNationalCountryName": .machine,
        "catalogMixLastShown": .machine,
        // Travels, element-wise: one statement per station heard, the play
        // moment as its time, a removal as its tombstone (decided 05.09.).
        "radioRecents": .travels,
        "radioRecentTimes": .travels,
        "radioPlayCounts": .machine,
        "radioMostPlayedStations": .machine,
        "radioDiscoveryCache": .machine,
        "userChoiceStamps": .machine,
    ]

    /// Dynamic key families (`<prefix><id>`) → class.
    static let prefixes: [String: UserChoiceClass] = [
        "playbackRate.": .travels,
        "playedTail.": .travels,
        // The free feed of a paid show: an address, the same on every device.
        "podcastFreeTwin.": .travels,
        "podcastInboxMode.": .travels,
        "podcastNotify.": .travels,
        // Every per-show setting travels; the show rate was the one
        // device-class exception without a stated reason, and the rate
        // per title travels already.
        "podcastShowRate.": .travels,
        // Sort and filter of one show page are chosen like the tab's sort,
        // and the tab's travels. The id is the feed hash or the server's
        // item id, the same on every device.
        "podcastSort.": .travels,
        "podcastFilter.": .travels,
        // What a Subsonic server said about itself, kept per server: the
        // API version, the negotiated sign-in mode, the reported type and
        // version. Each device asks its server itself.
        "subsonicApiVersion.": .machine,
        "subsonicSignIn.": .machine,
        "subsonicType.": .machine,
        "subsonicServerVersion.": .machine,
        "navidromeRekeyed.": .machine,
        // The automatism per show: on or off and the count stay on the
        // device, like their values for all shows; the direction travels;
        // its last error is the device's own state.
        "podcastAutoDownload.": .device,
        "podcastAutoDownloadMode.": .device,
        "podcastAutoDownloadSince.": .device,
        "podcastAutoDownloadKeep.": .device,
        "podcastAutoDownloadDirection.": .travels,
        "podcastAutoDownloadError.": .machine,
        "localPosition.": .machine,
        "flushedPosition.": .machine,
        "jumpRing.": .machine,
    ]

    /// The travelling static SCALARS (element-wise families are handled by
    /// their group namespaces below, not as whole-value scalars).
    static let travelingScalars: [String] = [
        "librarySortOption", "librarySortAscending", "libraryFilterOption",
        "podcastSortOption", "podcastFilterOption", "musicSortOption",
        "radioGenreCountryCodes",
        "radioChosenCountryCode", "radioChosenCountryName",
        "radioRegionCountryCode", "radioRegionCountryName", "radioRegionState",
        "lastPlayedItemId",
        // What the person chose is the same on both
        // devices. Playback habits, appearance, which tabs and sources and
        // rows they want, what the app may ask the net, and the per-show
        // behaviour switches.
        "skipInterval", "musicSkipInterval", "defaultPlaybackRate",
        "smartRewind", "autoPlayNextInSeries",
        "appearanceOverride", "bottomBarAccent",
        "audiobooksTabEnabled", "podcastsTabEnabled", "musicTabEnabled", "radioTabEnabled",
        "radioEnabled", "subsonicEnabled", "jellyfinEnabled", "rssEnabled",
        "pinchflatEnabled", "absPodcastsEnabled", "absAudiobooksEnabled",
        "gpodderEnabled", "gpodderSyncsPremiumFeeds",
        "homeRecommendations", "suggestionLanguages", "appleCatalogEnabled",
        "radioLogoChainEnabled", "musicArtistImagesOnline", "musicLyricsOnlineLookup",
        "musicHighResCovers", "librivoxRowsEnabled", "archivePopularEnabled",
        "jamendoRowEnabled", "freeClassicalEnabled", "netlabelsRowEnabled",
        "shellacRowsEnabled", "freeCatalogsMasterEnabled", "freeAudiobooksEnabled",
        "gutenbergSourceEnabled", "podcastIndexSourceEnabled", "feedArtworkSourceEnabled",
        "rowHomeDiscoverMusicVisible", "rowHomeRecentlyAddedVisible", "rowBooksRecentVisible",
        "jamendoRowVisible", "rowPodcastsRadioPlaysVisible", "rowPodcastsRecommendedVisible",
        "rowRadioCatalogVisible",
        "coListenedHidden", "podcastAutoSaveOnPlay", "podcastSubscribeToServer",
        "podcastNewEpisodeNotifications",
        "podcastInboxModeAll", "podcastAutoDownloadDirectionAll", "playedTailSeconds",
    ]

    static let travelingPrefixes: [String] = [
        "playbackRate.", "podcastInboxMode.", "podcastNotify.",
        "podcastShowRate.", "podcastSort.", "podcastFilter.", "podcastAutoDownloadDirection.",
        "playedTail.", "podcastFreeTwin.",
    ]

    /// Choices that used to travel and whose feature is gone. Leaving the
    /// catalog is not enough: the cloud document still carries them, and a
    /// device without a local value would adopt them back as a plain value.
    /// So a reconcile takes them out of the document the way the overflow
    /// of rates goes (removed, never a tombstone), and the device forgets
    /// them locally. Nothing is written for them that could travel.
    /// The episode limit per show and for all shows: no count takes an
    /// episode out of a show any more.
    static let retiredScalars: [String] = ["podcastEpisodeLimitAll"]
    static let retiredPrefixes: [String] = ["podcastEpisodeLimit."]

    static func isRetired(_ key: String) -> Bool {
        retiredScalars.contains(key) || retiredPrefixes.contains { key.hasPrefix($0) }
    }

    /// `subscription.<feedKey>` ⇒ the feed address, stamped with the
    /// moment of subscribing; a tombstone is the unsubscribe. The travel
    /// form of the subscription list for devices without a podcast server.
    static let subscriptionPrefix = "subscription."

    // Cloud namespaces of the element-wise families. Distinct from every
    // stored defaults key, so blob keys never collide with scalar keys.
    static let favoritePrefix = "radioFavorite."
    /// `radioRecent.<station id>` ⇒ the station, stamped with the moment it
    /// was played; a tombstone is the removal from "Listen Again".
    static let recentStationPrefix = "radioRecent."
    /// `radioManual.<station id>` ⇒ the station a person entered by hand,
    /// stamped with the moment they added it; a tombstone is the removal.
    /// The list is a choice like the favourites, so it travels the same
    /// way, element by element instead of as a blob.
    static let manualStationPrefix = "radioManual."
    /// `radioVariant.<variant key>` ⇒ the chosen stream address of a
    /// station; a tombstone means "back to the catalogue's best".
    static let variantPrefix = "radioVariant."
    static let searchPrefix = "recentSearch."
    static let hiddenPrefix = "continueHidden."
    static let premiumMarkPrefix = "premiumMark."
    static let feedBlockPrefix = "feedBlock."
    /// `knownServer.<service>|<url>` ⇒ the date it last worked.
    static let knownServerPrefix = "knownServer."

    /// The harness seeds a library into a simulator: stations, albums,
    /// shows. Such an entry once reached a real account, and a seeded
    /// station stood among a person's own ones.
    ///
    /// The forms are ANCHORED, because the consequence is a deletion. An
    /// rss id carries the episode's whole address (`rss:<hash>:https://…`),
    /// so an unanchored "seed-book" would have matched a real show at
    /// `example.org/seed-book-club/ep1` and silently dropped its stand.
    /// The same class as "Crimea" matching "crime", with a deletion at the
    /// end of it.
    ///
    /// A seed id starts with its namespace; the bare names the harness
    /// gives library items count only as the WHOLE id.
    static let harnessSeedPrefixes = ["radio:manual:seed-", "radio:rb:seed-",
                                      "sub:album:seed-", "sub:song:seed-", "sub:playlist:seed-",
                                      "lva:seed-", "lv:seed-", "rss:seed:", "abspod:seed-"]
    /// Ids the harness uses verbatim, matched in full and never as a part.
    static let harnessSeedExactPrefixes = ["seed-book", "seed-playlist", "seed-artist",
                                           "seed-show", "filler-show-", "seed-feed"]

    /// Is this id a leftover of the harness? Asked on both directions of
    /// the reconcile: such an entry never travels out and never comes in.
    static func isHarnessSeed(id: String) -> Bool {
        if harnessSeedPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        // The bare forms only where the id IS one of them (the harness
        // numbers them: "seed-book-1", "filler-show-4"); never inside a
        // longer id, which is always a real address.
        return harnessSeedExactPrefixes.contains { id.hasPrefix($0) && !id.contains("/") && !id.contains(":") }
    }

    /// The same question for a cloud key: the id stands behind the
    /// family's prefix, so the prefix is stripped before asking. Asking
    /// the whole key would have missed the anchor.
    static func isHarnessSeed(cloudKey key: String) -> Bool {
        let families = [favoritePrefix, recentStationPrefix, hiddenPrefix,
                        premiumMarkPrefix, feedBlockPrefix, searchPrefix,
                        subscriptionPrefix, knownServerPrefix]
        for family in families where key.hasPrefix(family) {
            return isHarnessSeed(id: String(key.dropFirst(family.count)))
        }
        return isHarnessSeed(id: key)
    }

    /// The blob keeps at most this many `playbackRate.` STATEMENTS (newest by
    /// event time win). A title that moved to Navidrome's new ids says one
    /// thing under two keys, so while a moved stock carries both, the blob
    /// can hold up to twice as many keys (about 78 KB instead of 39 KB at the
    /// measured 78 bytes per key), well inside the shared 1 MB budget.
    /// Per-title rates are unbounded locally. Precedent: the statistics item
    /// pot's top-500.
    static let playbackRateCap = 500
}

/// One cloud statement: a value with the EVENT time of the user action that
/// produced it, or a tombstone ("deliberately cleared") with that event time.
/// "Never set" is the ABSENCE of an entry. The difference the merge lives on.
nonisolated struct UserChoiceEntry: Equatable {
    /// nil = tombstone.
    var value: UserChoiceValue?
    /// Event time in ms since 1970. 0 = pre-family stock (set at an unknown
    /// time): loses against every real action, wins against nothing.
    var t: Double

    /// Plist form for the KVS blob: ["t": ms] + ("v" when not a tombstone).
    var plist: [String: Any] {
        var out: [String: Any] = ["t": t]
        if let value { out["v"] = value.plist }
        return out
    }

    static func from(plist: Any?) -> UserChoiceEntry? {
        guard let dict = plist as? [String: Any],
              let t = (dict["t"] as? NSNumber)?.doubleValue else { return nil }
        return UserChoiceEntry(value: UserChoiceValue.from(plist: dict["v"]), t: t)
    }
}

/// The plist scalar types a choice can hold. Typed (not `Any`) so equality is
/// honest. NSNumber blurs Bool/Int, and the merge's equal-value guard must
/// not mistake `1` for `true`.
nonisolated enum UserChoiceValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case stringList([String])
    case data(Data)

    var plist: Any {
        switch self {
        case .string(let v): return v
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .stringList(let v): return v
        case .data(let v): return v
        }
    }

    static func from(plist: Any?) -> UserChoiceValue? {
        switch plist {
        case nil: return nil
        case let v as String: return .string(v)
        case let v as Data: return .data(v)
        case let v as [String]: return .stringList(v)
        case let v as NSNumber:
            // CFBoolean is its own type. Every other NSNumber is numeric.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            if let i = v as? Int, v.doubleValue == Double(i),
               !String(cString: v.objCType).contains("d") { return .int(i) }
            return .double(v.doubleValue)
        default: return nil
        }
    }
}

/// The pure merge core: one decision per key, no store access, fully
/// unit-testable. Event-time semantics: the last USER action wins; sync and
/// restore times never stamp (the reviver lesson, applied to choices).
nonisolated enum UserChoiceMerge {

    enum Decision: Equatable {
        /// Cloud is newer. Write its value (or clear on tombstone) locally.
        case adopt
        /// Same value on both sides, cloud stamp newer. Align the local
        /// stamp, touch nothing else (prevents stamp ping-pong).
        case adoptStampOnly
        /// Local is newer (or cloud has nothing). Write the local statement
        /// to the blob with its event time.
        case push(Double)
        case none
    }

    /// The subscriptions as one reconcile finds them, counted, never named.
    struct SubscriptionCount: Equatable {
        /// Held on this device; nil while the store has not loaded.
        let local: Int?
        /// Subscribed in the document.
        let document: Int
        /// Unsubscribed in the document (tombstones).
        let removed: Int
        /// Subscribed in the document and not held here; nil when `local`
        /// is unknown. A feed that travels and is not followed shows here.
        let unheld: Int?
        /// What `decide` says for each of the unheld ones: only `adopt`
        /// hands a feed to the store, every other answer keeps it away.
        var adopt = 0, push = 0, stampOnly = 0, none = 0
    }

    /// Counts what the document says about subscriptions against what this
    /// device holds, so a subscription that does not arrive can be told
    /// apart from one that never left, and says per unheld one what the
    /// merge decides for it.
    static func subscriptionCount(local: Set<String>?, localEntries: [String: UserChoiceEntry],
                                  blob: [String: Any]) -> SubscriptionCount {
        var subscribed: [String: UserChoiceEntry] = [:]
        var removed = 0
        for (key, raw) in blob where key.hasPrefix(UserChoiceCatalog.subscriptionPrefix) {
            guard let entry = UserChoiceEntry.from(plist: raw) else { continue }
            if case .string? = entry.value {
                subscribed[String(key.dropFirst(UserChoiceCatalog.subscriptionPrefix.count))] = entry
            } else {
                removed += 1
            }
        }
        var count = SubscriptionCount(local: local?.count, document: subscribed.count, removed: removed,
                                      unheld: local.map { Set(subscribed.keys).subtracting($0).count })
        guard let local else { return count }
        for (feedKey, cloud) in subscribed where !local.contains(feedKey) {
            switch decide(local: localEntries[UserChoiceCatalog.subscriptionPrefix + feedKey], cloud: cloud) {
            case .adopt: count.adopt += 1
            case .push: count.push += 1
            case .adoptStampOnly: count.stampOnly += 1
            case .none: count.none += 1
            }
        }
        return count
    }

    /// `local` is nil when the key was NEVER set locally (no value, no stamp).
    /// A local tombstone is an entry with `value == nil` and the clear's time.
    static func decide(local: UserChoiceEntry?, cloud: UserChoiceEntry?) -> Decision {
        switch (local, cloud) {
        case (nil, nil):
            return .none
        case (let l?, nil):
            return .push(l.t)
        case (nil, .some):
            return .adopt
        case (let l?, let c?):
            if l.value == c.value {
                return c.t > l.t ? .adoptStampOnly : .none
            }
            if c.t > l.t { return .adopt }
            if l.t > c.t { return .push(l.t) }
            // Equal stamps, different values. A held VALUE against a
            // tombstone with the very same event stamp is no real conflict:
            // a person's clear carries its own moment, so an equal stamp
            // only comes from a tombstone that was derived from the value's
            // stamp (an old install's loop) or stored beside it. The device
            // that holds the value writes it back, and the other side
            // adopts it instead of waiting forever. Stamp zero is
            // pre-family stock against a legacy statement and stays the
            // honest tie: writing it back would revive a decided removal.
            if l.value != nil, c.value == nil, l.t > 0 { return .push(l.t) }
            // Otherwise an honest tie. Keep local, write nothing. The next
            // real action on either side resolves it.
            return .none
        }
    }

    /// Builds the local entry for `decide` from what the stores know. A value
    /// without a stamp is pre-family stock → t = 0. No value and no stamp =
    /// never set → nil. No value WITH a stamp = local tombstone.
    static func localEntry(value: UserChoiceValue?, stamp: Double?) -> UserChoiceEntry? {
        if value == nil && stamp == nil { return nil }
        return UserChoiceEntry(value: value, t: stamp ?? 0)
    }

    /// Merged recent-searches list: live elements sorted by event time (newest
    /// first), pre-family ties (t = 0) keep their local order, capped. Cap
    /// eviction is NOT a tombstone. An evicted term simply falls off the end
    /// here; only explicit remove/clear travels as a tombstone.
    static func mergedSearches(elements: [(term: String, entry: UserChoiceEntry)],
                               localOrder: [String], cap: Int) -> [String] {
        let localIndex = Dictionary(uniqueKeysWithValues:
            localOrder.enumerated().map { ($1, $0) })
        return elements
            .filter { $0.entry.value != nil }
            .sorted { a, b in
                if a.entry.t != b.entry.t { return a.entry.t > b.entry.t }
                let ia = localIndex[a.term] ?? Int.max
                let ib = localIndex[b.term] ?? Int.max
                if ia != ib { return ia < ib }
                return a.term < b.term
            }
            .map(\.term)
            .prefix(cap).map { $0 }
    }

    /// The last-heard stations across the person's devices: every statement
    /// with a station, newest play first (tombstones drop out), capped like
    /// the local ring. Both devices compute the same list from the blob.
    /// A tie in time keeps the LOCAL order (a ring imported into the blob
    /// at once carries one stamp for every station), the id decides only
    /// between stations this device never held. Same shape as the searches.
    static func mergedRecents(elements: [(station: RadioStation, t: Double)],
                              localOrder: [String], cap: Int) -> [(station: RadioStation, t: Double)] {
        let localIndex = Dictionary(localOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<String> = []
        return elements
            .sorted { a, b in
                if a.t != b.t { return a.t > b.t }
                let ia = localIndex[a.station.id] ?? Int.max
                let ib = localIndex[b.station.id] ?? Int.max
                if ia != ib { return ia < ib }
                return a.station.id < b.station.id
            }
            .filter { seen.insert($0.station.id).inserted }
            .prefix(cap).map { $0 }
    }

    /// Favorites keep the LOCAL order; adopted stations append at the end,
    /// oldest adopted first. A reconcile must never reshuffle the row the
    /// person arranged by favoriting over time.
    static func favoritesAppending(local: [RadioStation],
                                   adopted: [(station: RadioStation, t: Double)]) -> [RadioStation] {
        let known = Set(local.map(\.id))
        let fresh = adopted
            .filter { !known.contains($0.station.id) }
            .sorted { a, b in a.t != b.t ? a.t < b.t : a.station.id < b.station.id }
            .map(\.station)
        return local + fresh
    }

    /// Keeps the newest `cap` statements of one dynamic family in the blob.
    /// Returns the keys to DROP. `statement` names what a key says: an old
    /// and a new key of one title (Navidrome's new ids) are ONE statement
    /// and cost one place, ranked by the newer of the two; counted raw, a
    /// moved stock filled the cap twice. Deterministic tie-break so two
    /// devices prune identically.
    static func overflowKeys(entries: [(key: String, t: Double)], cap: Int,
                             statement: (String) -> String = { $0 }) -> [String] {
        var newest: [String: Double] = [:]
        var keys: [String: [String]] = [:]
        for entry in entries {
            let said = statement(entry.key)
            newest[said] = max(newest[said] ?? -.greatestFiniteMagnitude, entry.t)
            keys[said, default: []].append(entry.key)
        }
        guard newest.count > cap else { return [] }
        let ranked: [(statement: String, t: Double)] = newest
            .map { (statement: $0.key, t: $0.value) }
            .sorted { a, b in a.t != b.t ? a.t > b.t : a.statement < b.statement }
        return ranked.dropFirst(cap).flatMap { (keys[$0.statement] ?? []).sorted() }
    }
}
