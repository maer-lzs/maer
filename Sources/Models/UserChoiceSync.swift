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

        // Device: playback defaults (context may differ per device)
        "skipInterval": .device,
        "defaultPlaybackRate": .device,
        "smartRewind": .device,
        "autoPlayNextInSeries": .device,
        // The duration the sleep timer was last started with. It belongs to
        // the situation a device is used in, not to the person: half an hour
        // on the bedside phone says nothing about the tablet in the kitchen.
        // The travelling set is a decided list, and this is not on it.
        "sleepTimerLastMinutes": .device,
        // Device: appearance
        "appearanceOverride": .device,
        "bottomBarAccent": .device,
        // Device: tab visibility
        "audiobooksTabEnabled": .device,
        "podcastsTabEnabled": .device,
        "musicTabEnabled": .device,
        "radioTabEnabled": .device,
        // Device: source switches (hang on per-device credentials)
        "radioEnabled": .device,
        "subsonicEnabled": .device,
        "jellyfinEnabled": .device,
        "rssEnabled": .device,
        "pinchflatEnabled": .device,
        "absPodcastsEnabled": .device,
        "absAudiobooksEnabled": .device,
        "gpodderEnabled": .device,
        "gpodderSyncsPremiumFeeds": .device,
        "serverlessMode": .device,
        // Device: network/privacy stances
        "homeRecommendations": .device,
        "suggestionLanguages": .device,
        "appleCatalogEnabled": .device,
        "radioLogoChainEnabled": .device,
        "musicArtistImagesOnline": .device,
        "musicLyricsOnlineLookup": .device,
        "musicHighResCovers": .device,
        "librivoxRowsEnabled": .device,
        "archivePopularEnabled": .device,
        "jamendoRowEnabled": .device,
        "freeClassicalEnabled": .device,
        "netlabelsRowEnabled": .device,
        "shellacRowsEnabled": .device,
        "freeCatalogsMasterEnabled": .device,
        "freeAudiobooksEnabled": .device,
        // Device: the two-question rebuild (source allowed x row visible).
        // Same class as every other source/row switch above: which services
        // a device may ask and which rows it shows belong to the situation
        // the device is used in.
        "gutenbergSourceEnabled": .device,
        "podcastIndexSourceEnabled": .device,
        "feedArtworkSourceEnabled": .device,
        "rowHomeDiscoverMusicVisible": .device,
        "rowHomeRecentlyAddedVisible": .device,
        "rowBooksRecentVisible": .device,
        "jamendoRowVisible": .device,
        "rowPodcastsRadioPlaysVisible": .device,
        "rowPodcastsRecommendedVisible": .device,
        "rowRadioCatalogVisible": .device,
        // Device: misc deliberate per-device choices
        "warnCellularDownload": .device,
        "driveModeCarRouteUID": .device,
        "driveModeCarRouteName": .device,
        "driveModeAutoStart": .device,
        "podcastICloudSync": .device,
        "podcastNewEpisodeNotifications": .device,
        "lastSelectedTab": .device,
        "podcastAutoSaveOnPlay": .device,
        "podcastSubscribeToServer": .device,
        "radioManualStations": .device,

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
        "sourcesTwoQuestionsMigrated": .machine,
        "downloadExtensionRepairV2": .machine,
        "downloadDeepValidationV1": .machine,
        // Machine: setup state and derived caches
        "selectedLibraryId": .machine,
        "subsonicContentType": .machine,
        "subsonicServesMusic": .machine,
        "subsonicServesAudiobooks": .machine,
        "subsonicLibraries": .machine,
        "subsonicLibraryAssignment": .machine,
        "librivoxImportLibraryId": .machine,
        "librivoxImportFolderId": .machine,
        "pinchflatMirroredFeedKeys": .machine,
        "radioRegionQueryNames": .machine,
        "radioNationalCountryCode": .machine,
        "radioNationalCountryName": .machine,
        "catalogMixLastShown": .machine,
        "radioRecents": .machine,
        "radioRecentTimes": .machine,
        "radioPlayCounts": .machine,
        "radioMostPlayedStations": .machine,
        "radioDiscoveryCache": .machine,
        // Per-station bitrate override: network ergonomics of THIS device
        // (cellular vs. wifi), not a content judgement.
        "radioVariantSelection": .device,
        "userChoiceStamps": .machine,
    ]

    /// Dynamic key families (`<prefix><id>`) → class.
    static let prefixes: [String: UserChoiceClass] = [
        "playbackRate.": .travels,
        "podcastInboxMode.": .travels,
        "podcastNotify.": .travels,
        "podcastEpisodeLimit.": .travels,
        "podcastShowRate.": .device,
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
    ]

    static let travelingPrefixes: [String] = [
        "playbackRate.", "podcastInboxMode.", "podcastNotify.", "podcastEpisodeLimit.",
    ]

    // Cloud namespaces of the element-wise families. Distinct from every
    // stored defaults key, so blob keys never collide with scalar keys.
    static let favoritePrefix = "radioFavorite."
    static let searchPrefix = "recentSearch."
    static let hiddenPrefix = "continueHidden."
    static let premiumMarkPrefix = "premiumMark."
    static let feedBlockPrefix = "feedBlock."
    /// `knownServer.<service>|<url>` ⇒ the date it last worked.
    static let knownServerPrefix = "knownServer."

    /// The blob keeps at most this many `playbackRate.` entries (newest by
    /// event time win). Per-title rates are unbounded locally, the shared
    /// 1 MB budget is not. Precedent: the statistics item pot's top-500.
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
            // Equal stamps, different values: honest tie. Keep local, write
            // nothing. The next real action on either side resolves it.
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

    /// Keeps the newest `cap` entries of one dynamic family in the blob.
    /// Returns the keys to DROP. Deterministic tie-break so two devices prune
    /// identically.
    static func overflowKeys(entries: [(key: String, t: Double)], cap: Int) -> [String] {
        guard entries.count > cap else { return [] }
        return entries
            .sorted { a, b in a.t != b.t ? a.t > b.t : a.key < b.key }
            .dropFirst(cap)
            .map(\.key)
    }
}
