// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Central place for all UserDefaults keys. Per-book keys are pruned via
/// `cleanupPerBookKeys` once a book no longer exists in the (full) library.
// nonisolated: pure key helpers, must be callable from background tasks
// (the project uses default MainActor isolation).
nonisolated enum AppStorageKeys {
    static let skipInterval = "skipInterval"
    /// The skip width for music, remembered apart from the spoken word.
    static let musicSkipInterval = "musicSkipInterval"
    /// Last bottom-bar cover accent (RGBA components). Restored at launch
    /// so the bar never falls back to neutral once an item has ever played.
    static let bottomBarAccent = "bottomBarAccent"
    /// Teil 5: ONE opt-out for the Home recommendation sections (Rediscover +
    /// Discover); default on.
    static let homeRecommendations = "homeRecommendations"
    /// Speed for books that have no per-book rate saved yet.
    static let defaultPlaybackRate = "defaultPlaybackRate"
    /// Resume slightly earlier after a longer pause (default ON).
    static let smartRewind = "smartRewind"
    /// "system" | "light" | "dark". Overrides the system appearance.
    static let appearance = "appearanceOverride"
    /// Ask before downloading without Wi-Fi (default ON).
    static let warnCellularDownload = "warnCellularDownload"
    /// Library chosen in the settings; empty/unknown → first library.
    static let selectedLibraryId = "selectedLibraryId"
    /// Start the next unfinished book of the series when one ends (default OFF).
    static let autoPlayNextInSeries = "autoPlayNextInSeries"
    /// Bookmark create/delete ops that have not reached the server yet.
    static let pendingBookmarkOps = "pendingBookmarkOps"
    /// Optional PodcastIndex key for podcast search (the iTunes catalog needs
    /// none). Low sensitivity → UserDefaults.
    static let podcastIndexKey = "podcastIndexKey"
    /// Old UserDefaults key of the secret. Kept only for the one-time
    /// migration into the keychain (see below).
    static let podcastIndexSecret = "podcastIndexSecret"

    /// The API key is a public identifier → UserDefaults is enough.
    static var podcastIndexKeyValue: String {
        get { UserDefaults.standard.string(forKey: podcastIndexKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: podcastIndexKey) }
    }

    /// The secret is a credential → keychain instead of plaintext UserDefaults.
    /// A leftover UserDefaults value is migrated on first access.
    static var podcastIndexSecretValue: String {
        if let s = KeychainStore.load(forKey: KeychainKey.podcastIndexSecret), !s.isEmpty {
            return s
        }
        let old = UserDefaults.standard.string(forKey: podcastIndexSecret) ?? ""
        if !old.isEmpty {
            KeychainStore.save(old, forKey: KeychainKey.podcastIndexSecret)
            UserDefaults.standard.removeObject(forKey: podcastIndexSecret)
        }
        return old
    }

    static func setPodcastIndexSecret(_ value: String) {
        if value.isEmpty {
            KeychainStore.delete(forKey: KeychainKey.podcastIndexSecret)
        } else {
            KeychainStore.save(value, forKey: KeychainKey.podcastIndexSecret)
        }
        UserDefaults.standard.removeObject(forKey: podcastIndexSecret)
    }

    /// The ONE resolution rule for app keys. A user-entered value beats
    /// the build-injected one (Jamendo and PodcastIndex share it).
    nonisolated static func resolvedAppKey(user: String, injected: String?) -> String {
        user.isEmpty ? (injected ?? "") : user
    }

    /// Effective PodcastIndex credentials: user entry first, then the
    /// build-injected app key (`Maer-Info.plist`, values via
    /// `Config/AppKeys.local.xcconfig`. Never in the repo). The Settings
    /// field binds to `podcastIndexKeyValue` and keeps showing only the
    /// user's own entry.
    static var podcastIndexEffectiveKey: String {
        resolvedAppKey(user: podcastIndexKeyValue,
                       injected: Bundle.main.object(forInfoDictionaryKey: "PodcastIndexKey") as? String)
    }

    static var podcastIndexEffectiveSecret: String {
        resolvedAppKey(user: podcastIndexSecretValue,
                       injected: Bundle.main.object(forInfoDictionaryKey: "PodcastIndexSecret") as? String)
    }

    static var podcastIndexConfigured: Bool {
        !podcastIndexEffectiveKey.isEmpty && !podcastIndexEffectiveSecret.isEmpty
    }

    /// May PodcastIndex actually be asked? Credentials alone answered this
    /// before; with the sources page the source switch joins in, otherwise
    /// its row would show a switch that switches nothing.
    static var podcastIndexActive: Bool {
        podcastIndexConfigured && ExternalSources.isAllowed(ExternalSources.podcastIndex)
    }
    /// PER gpodder account: "private server: sync premium feeds too". OFF
    /// keeps token feeds on the device. The switch exists because for a
    /// self-hoster their own oPodSync IS the trusted place; the lock on
    /// token feeds protects the FOREIGN-server case (gpodder.net), not the
    /// own one. Pinchflat mirrors stay out either way. Their reason is
    /// reachability, not secrecy.
    /// Default ON: both devices share ONE subscription list, premium feeds
    /// included. A device that never touched the switch takes the default; a
    /// deliberate OFF stays off, because the stored value wins over the default.
    static let gpodderSyncsPremiumFeeds = "gpodderSyncsPremiumFeeds"
    nonisolated static var gpodderSyncsPremiumFeedsEnabled: Bool {
        bool(gpodderSyncsPremiumFeeds, default: true)
    }

    // MARK: - gpodder / oPodSync (open podcast sync next to iCloud/ABS)

    static let gpodderServerURL = "gpodderServerURL"
    static let gpodderUsername = "gpodderUsername"
    static let gpodderEnabled = "gpodderEnabled"
    /// Rolling "since" marker of the gpodder API (server returns Int timestamps).
    static let gpodderEpisodeSince = "gpodderEpisodeSince"
    /// Time (s) up to which episode actions have already been pushed.
    static let gpodderLastEpisodePush = "gpodderLastEpisodePush"
    /// Last synced subscription state (normalised feed URLs). Basis for the
    /// 3-way merge so unsubscribes are detected and propagated.
    static let gpodderLastSyncedFeeds = "gpodderLastSyncedFeeds"
    /// 2–3-feed removals held for a second consecutive-sync confirmation
    /// (normalised keys). One per side; a diff must persist across two runs.
    static let gpodderPendingRemoveLocal = "gpodderPendingRemoveLocal"
    static let gpodderPendingRemoveServer = "gpodderPendingRemoveServer"
    /// Feeds found only on the gpodder server when this device went on with
    /// another account (normalised keys): they stay there, unseen.
    static let gpodderLeftOnServer = "gpodderLeftOnServer"

    static var gpodderServerURLValue: String {
        get { UserDefaults.standard.string(forKey: gpodderServerURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: gpodderServerURL) }
    }
    static var gpodderUsernameValue: String {
        get { UserDefaults.standard.string(forKey: gpodderUsername) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: gpodderUsername) }
    }
    static var gpodderEnabledValue: Bool {
        get { UserDefaults.standard.bool(forKey: gpodderEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: gpodderEnabled) }
    }
    /// Password → keychain (credential, never plaintext UserDefaults).
    static var gpodderPasswordValue: String {
        KeychainStore.load(forKey: KeychainKey.gpodderPassword) ?? ""
    }
    static func setGpodderPassword(_ value: String) {
        if value.isEmpty { KeychainStore.delete(forKey: KeychainKey.gpodderPassword) }
        else { KeychainStore.save(value, forKey: KeychainKey.gpodderPassword) }
    }

    /// Stable device id for gpodder sync (created once, then fixed).
    static var gpodderDeviceIdValue: String {
        if let id = UserDefaults.standard.string(forKey: "gpodderDeviceId"), !id.isEmpty { return id }
        let id = "maer-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(id, forKey: "gpodderDeviceId")
        return id
    }

    static var gpodderConfigured: Bool {
        !gpodderServerURLValue.isEmpty && !gpodderUsernameValue.isEmpty && !gpodderPasswordValue.isEmpty
    }

    // MARK: - Subsonic / Navidrome (music source)

    /// The user chose to run WITHOUT an ABS server (podcasts-first);
    /// every source stays individually attachable in the settings.
    static let serverlessMode = "serverlessMode"
    static var serverlessModeValue: Bool {
        get { UserDefaults.standard.bool(forKey: serverlessMode) }
        set { UserDefaults.standard.set(newValue, forKey: serverlessMode) }
    }

    // MARK: - Radio

    /// Radio source toggle. The tab appears once switched on.
    static let radioEnabled = "radioEnabled"
    /// May APPLE's catalog be contacted at all? Default on; off is
    /// a hard no-request gate. Every Apple path resolves through
    /// `PodcastDirectorySelection`, nothing asks Apple behind this flag.
    static let appleCatalogEnabled = "appleCatalogEnabled"
    static var appleCatalogEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: appleCatalogEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: appleCatalogEnabled) }
    }

    static var radioEnabledValue: Bool {
        // Everything on at the start: radio needs no account and
        // no server. A default of off hid a whole area from everyone who
        // never found the toggle.
        get { UserDefaults.standard.object(forKey: radioEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: radioEnabled) }
    }

    static let subsonicServerURL = "subsonicServerURL"
    static let subsonicUsername = "subsonicUsername"
    static let subsonicEnabled = "subsonicEnabled"

    static var subsonicServerURLValue: String {
        get { UserDefaults.standard.string(forKey: subsonicServerURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: subsonicServerURL) }
    }
    static var subsonicUsernameValue: String {
        get { UserDefaults.standard.string(forKey: subsonicUsername) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: subsonicUsername) }
    }
    static var subsonicEnabledValue: Bool {
        get { UserDefaults.standard.bool(forKey: subsonicEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: subsonicEnabled) }
    }
    /// Password → keychain (credential, never plaintext UserDefaults).
    static var subsonicPasswordValue: String {
        KeychainStore.load(forKey: KeychainKey.subsonicPassword) ?? ""
    }
    static func setSubsonicPassword(_ value: String) {
        if value.isEmpty { KeychainStore.delete(forKey: KeychainKey.subsonicPassword) }
        else { KeychainStore.save(value, forKey: KeychainKey.subsonicPassword) }
    }

    // Jellyfin music server (Etappe 2). Mirrors the Subsonic key family.
    static let jellyfinServerURL = "jellyfinServerURL"
    static let jellyfinUsername = "jellyfinUsername"
    static let jellyfinEnabled = "jellyfinEnabled"
    static let jellyfinUserId = "jellyfinUserId"
    static let jellyfinDeviceId = "jellyfinDeviceId"
    /// The books library the server reported, empty when it has none. A
    /// remembered server FACT, not a choice: the activation gate is a
    /// synchronous question and cannot ask the server.
    static let jellyfinBooksViewId = "jellyfinBooksViewId"

    static var jellyfinServerURLValue: String {
        get { UserDefaults.standard.string(forKey: jellyfinServerURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: jellyfinServerURL) }
    }
    static var jellyfinUsernameValue: String {
        get { UserDefaults.standard.string(forKey: jellyfinUsername) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: jellyfinUsername) }
    }
    static var jellyfinEnabledValue: Bool {
        get { UserDefaults.standard.bool(forKey: jellyfinEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: jellyfinEnabled) }
    }
    static var jellyfinBooksViewIdValue: String {
        get { UserDefaults.standard.string(forKey: jellyfinBooksViewId) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: jellyfinBooksViewId) }
    }
    static var jellyfinUserIdValue: String {
        get { UserDefaults.standard.string(forKey: jellyfinUserId) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: jellyfinUserId) }
    }
    /// Stable per-install device id (Jellyfin session identity).
    static var jellyfinDeviceIdValue: String {
        if let existing = UserDefaults.standard.string(forKey: jellyfinDeviceId) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: jellyfinDeviceId)
        return fresh
    }
    /// Password + access token → keychain (credentials, never UserDefaults).
    static var jellyfinPasswordValue: String {
        KeychainStore.load(forKey: KeychainKey.jellyfinPassword) ?? ""
    }
    static func setJellyfinPassword(_ value: String) {
        if value.isEmpty { KeychainStore.delete(forKey: KeychainKey.jellyfinPassword) }
        else { KeychainStore.save(value, forKey: KeychainKey.jellyfinPassword) }
    }
    static var jellyfinTokenValue: String {
        KeychainStore.load(forKey: KeychainKey.jellyfinToken) ?? ""
    }
    static func setJellyfinToken(_ value: String) {
        if value.isEmpty { KeychainStore.delete(forKey: KeychainKey.jellyfinToken) }
        else { KeychainStore.save(value, forKey: KeychainKey.jellyfinToken) }
    }

    /// The Mär sync service the person set up: the address and the account
    /// name here, the device's token in the keychain. An empty address is
    /// no service; the secret is sent once at sign-in and kept nowhere.
    static let maerSyncURL = "maerSyncURL"
    static let maerSyncOwner = "maerSyncOwner"
    static var maerSyncURLValue: String {
        get { UserDefaults.standard.string(forKey: maerSyncURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: maerSyncURL) }
    }
    static var maerSyncOwnerValue: String {
        get { UserDefaults.standard.string(forKey: maerSyncOwner) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: maerSyncOwner) }
    }
    /// The service token, saying whether it is missing or could not be read.
    static var maerSyncTokenRead: KeychainRead {
        KeychainStore.read(forKey: KeychainKey.maerSyncToken)
    }
    static func setMaerSyncToken(_ value: String) {
        if value.isEmpty { KeychainStore.delete(forKey: KeychainKey.maerSyncToken) }
        else { KeychainStore.save(value, forKey: KeychainKey.maerSyncToken) }
    }

    /// The stored content type of the older single-capability form. Nothing
    /// reads it as an ANSWER any more. It is the input the pair falls back to
    /// for a stock that predates the pair, and it keeps being written so a
    /// downgrade to an older build still finds its one mode where it expects
    /// it.
    static let subsonicContentType = "subsonicContentType"

    /// What this Subsonic source is used FOR, as a pair of capabilities. THE
    /// answer, read by the provider, the activation gate and the settings
    /// surface.
    ///
    /// The read-back checks PRESENCE, not the boolean: `bool(forKey:)` on a key
    /// nobody ever wrote answers false, and two falses would read as "serves
    /// nothing". An activation statement the user never made, and the silent
    /// opposite of their stored choice. Only a pair that was actually written
    /// counts; everything else still reads its content type. Nothing is written
    /// on a read, so a stock nobody touched stays untouched.
    nonisolated static var subsonicModes: SourceModes {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: subsonicServesMusicKey) != nil
                || defaults.object(forKey: subsonicServesAudiobooksKey) != nil {
                return SourceModes(
                    servesMusic: defaults.bool(forKey: subsonicServesMusicKey),
                    servesAudiobooks: defaults.bool(forKey: subsonicServesAudiobooksKey))
            }
            return SourceModes.fromLegacyContentType(
                defaults.string(forKey: subsonicContentType))
        }
        set {
            UserDefaults.standard.set(newValue.legacyContentType, forKey: subsonicContentType)
            UserDefaults.standard.set(newValue.servesMusic, forKey: subsonicServesMusicKey)
            UserDefaults.standard.set(newValue.servesAudiobooks, forKey: subsonicServesAudiobooksKey)
        }
    }
    nonisolated static let subsonicServesMusicKey = "subsonicServesMusic"
    nonisolated static let subsonicServesAudiobooksKey = "subsonicServesAudiobooks"

    /// The server's music folders as last seen, and which type each feeds.
    /// Both are cached so the activation gate can answer synchronously. A
    /// tab must not appear and disappear around a network round trip.
    nonisolated static let subsonicLibraries = "subsonicLibraries"
    nonisolated static let subsonicLibraryAssignment = "subsonicLibraryAssignment"

    /// The libraries the Subsonic server answered last. An unreadable list
    /// is kept aside (`CorruptStore`, under `.corrupt`) with its line and
    /// reads as "not fetched yet", like an empty one: the next refresh of
    /// the server writes it again, and the line says why a tab was missing.
    nonisolated static var subsonicKnownLibraries: [SourceLibrary] {
        get {
            let outcome = CorruptStore.load([SourceLibrary].self, defaultsKey: subsonicLibraries,
                                            label: "SUBSONIC known libraries")
            // The bytes rest under `.corrupt` now; the key goes, so the many
            // readers of this list do not set aside and log again on every read.
            if case .corrupt = outcome { UserDefaults.standard.removeObject(forKey: subsonicLibraries) }
            return outcome.value ?? []
        }
        set {
            // bearable, because a list of names and ids always encodes; and if
            // it did not, the next refresh of the server writes it again.
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: subsonicLibraries)
        }
    }

    nonisolated static var subsonicAssignment: SourceLibraryAssignment {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: subsonicLibraryAssignment) as? [String: String] ?? [:]
            return SourceLibraryAssignment(byLibrary: raw.compactMapValues(MediaType.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.byLibrary.mapValues(\.rawValue),
                                      forKey: subsonicLibraryAssignment)
        }
    }

    /// Drive mode: the ONE remembered car audio-route UID (user-chosen from
    /// the connected outputs; empty = no auto-activation) + its display name.
    static let driveModeCarRouteUID = "driveModeCarRouteUID"
    static let driveModeCarRouteName = "driveModeCarRouteName"
    /// Explicit auto-start opt-in (default OFF. bool(forKey:)).
    static let driveModeAutoStart = "driveModeAutoStart"

    /// Suggestion/catalog language MULTI-selection ([String] codes);
    /// unset = device locale (SuggestionLanguages.effective).
    static let suggestionLanguages = "suggestionLanguages"

    // The three free-catalog SERVICE switches. Whom the app may contact
    // (librivox.org · archive.org · api.jamendo.com), each with its own
    // opt-out on the network-services page; defaults ON (object(forKey:)).
    //
    // WARNING, and it is the opposite of what the names say: these three
    // read like row switches and ARE services, while `freeClassicalEnabled`,
    // `netlabelsRowEnabled`, `shellacRowsEnabled` and `freeAudiobooksEnabled`
    // read like services and ARE areas (three of them on the ONE archive.org
    // service). The names lie. And they still must not be renamed: a new key
    // resets the setting of every existing user to the default, invisibly,
    // the same class as the keychain loss on a bundle-ID change. Read the
    // `feature:`/`service:` argument at the `…Active` accessors, not the
    // name, when deciding where a new switch belongs.
    static let librivoxRowsEnabled = "librivoxRowsEnabled"
    static let archivePopularEnabled = "archivePopularEnabled"
    static let jamendoRowEnabled = "jamendoRowEnabled"
    /// The user's OWN Jamendo client_id (beats the build-injected one).
    static let jamendoClientId = "jamendoClientId"
    /// The "Free Classical" AREA toggle. An area on the archive.org
    /// service, whose opt-out stays superior. The name reads like a service
    /// and is not one; see the warning at `librivoxRowsEnabled`. Not
    /// renameable (it would reset every user's setting).
    static let freeClassicalEnabled = "freeClassicalEnabled"
    /// The Creative-Commons netlabel area on
    /// archive.org. Same two levels as classical. This feature switch sits
    /// under the archive.org service opt-out and the catalog master switch.
    static let netlabelsRowEnabled = "netlabelsRowEnabled"
    /// The shellac surface (78 rpm genre shelves, georgeblood).
    static let shellacRowsEnabled = "shellacRowsEnabled"
    /// Remembered ABS import target (library picker on first use).
    static let librivoxImportLibraryId = "librivoxImportLibraryId"
    static let librivoxImportFolderId = "librivoxImportFolderId"
    /// The radio-logo fallback chain (Wikidata P154 → homepage
    /// touch icon) behind the gated favicon. Network-services opt-out.
    static let radioLogoChainEnabled = "radioLogoChainEnabled"
    nonisolated static var radioLogoChainEnabledValue: Bool {
        UserDefaults.standard.object(forKey: radioLogoChainEnabled) as? Bool ?? true
    }
    /// Normalized feed URLs the USER unsubscribed. Only these
    /// may propagate to the gpodder server without the two-sync confirmation.
    static let gpodderUserRemovedFeeds = "gpodderUserRemovedFeeds"
    /// Feed keys the user MARKED as premium manually (the escape
    /// hatch for unknown URL patterns). Feeds the ONE premium truth.
    static let premiumMarkedFeeds = "premiumMarkedFeeds"
    /// Feed keys of the Pinchflat-mirrored group, maintained by
    /// the subscriptions store. Read by the nonisolated premium truth
    /// (origin != nil is NEVER premium; server access is infrastructure).
    static let pinchflatMirroredFeedKeys = "pinchflatMirroredFeedKeys"
    /// Feed keys whose channel carries itunes:block/podcast:block.
    static let blockedFeedKeys = "blockedFeedKeys"
    /// The bridge ferry of the bundle-id move: import ran (machine
    /// marker), and the pending first-start notice (consumed by the UI).
    /// The "Free Audiobooks" AREA toggle. It lives at the "Free
    /// Catalogs" area of the source map (it used to sit in the audiobooks
    /// pill); the LibriVox service opt-out stays superior.
    static let freeAudiobooksEnabled = "freeAudiobooksEnabled"

    // Source keys of the sources that had no switch of their own before
    // the rebuild (the sources page names every foreign service, so
    // each needs its own answerable key; defaults stay true = today's
    // behaviour, the migration above is what carries an old OFF over).
    static let gutenbergSourceEnabled = "gutenbergSourceEnabled"
    static let podcastIndexSourceEnabled = "podcastIndexSourceEnabled"
    // radio-browser reuses the existing radio AREA key (`radioEnabled`);
    // a fresh key here would be a second switch for one service.
    static let feedArtworkSourceEnabled = "feedArtworkSourceEnabled"

    // Row keys of the rows that had no switch of their own before
    // (the rows page). Rows that already had one KEEP their key:
    // a renamed key would silently reset every stored choice.
    static let rowHomeDiscoverMusicVisible = "rowHomeDiscoverMusicVisible"
    static let rowHomeRecentlyAddedVisible = "rowHomeRecentlyAddedVisible"
    static let rowBooksRecentVisible = "rowBooksRecentVisible"
    /// The Jamendo ROW. `jamendoRowEnabled` is the SOURCE key now (its
    /// stored meaning was "may the app ask Jamendo", which is the privacy
    /// question); the presentation question gets its own fresh key.
    static let jamendoRowVisible = "jamendoRowVisible"
    static let rowPodcastsRadioPlaysVisible = "rowPodcastsRadioPlaysVisible"
    static let rowPodcastsRecommendedVisible = "rowPodcastsRecommendedVisible"
    static let rowRadioCatalogVisible = "rowRadioCatalogVisible"
    /// The Start row of free audiobooks and radio plays, apart from the
    /// catalog row of the audiobooks tab (`freeAudiobooksEnabled`); its
    /// first value is the old shared one (`AppRows.carryOldChoices`).
    static let rowHomeDiscoverBooksVisible = "rowHomeDiscoverBooksVisible"
    /// Rediscover on Start, apart from the recommendations (it shows only
    /// the person's own books); first value from `homeRecommendations`.
    static let rowHomeRediscoverVisible = "rowHomeRediscoverVisible"
    /// The chart row of the catalog page (Apple's charts), apart from the
    /// catalog row that holds the page.
    static let rowBooksChartsVisible = "rowBooksChartsVisible"
    /// The Pinchflat mirror's shows stand in the subscriptions like any
    /// feed (with their glyph) instead of in their own row. Off by default.
    static let podcastsPinchflatInSubscriptions = "podcastsPinchflatInSubscriptions"
    /// The premium feeds stand in the subscriptions like any feed (with
    /// their lock) instead of in their own row. Off by default.
    static let podcastsPremiumInSubscriptions = "podcastsPremiumInSubscriptions"

    // Radio-Picker-Kuratierung
    /// ALL raw name variants of the chosen region (the by-state query runs
    /// against every one; [String] via UserDefaults array).
    static let radioRegionQueryNames = "radioRegionQueryNames"
    /// Country implied by the chosen region (cascade step b).
    static let radioRegionCountryCode = "radioRegionCountryCode"
    static let radioRegionCountryName = "radioRegionCountryName"
    /// Explicitly chosen country (cascade step a. Beats every guess).
    /// The NATIONAL row has its own country now. Living where you are
    /// and coming from somewhere else are two different facts: the popular
    /// row of one country plus the home stations of another region. The
    /// region
    /// row keeps `radioRegionCountryCode`/`-Name` + `radioRegionState`.
    static let radioNationalCountryCode = "radioNationalCountryCode"
    static let radioNationalCountryName = "radioNationalCountryName"
    static let radioChosenCountryCode = "radioChosenCountryCode"
    static let radioChosenCountryName = "radioChosenCountryName"
    /// The GENRE pages' countries. A list, shared by all genres.
    /// Absent = never chosen (the cascade decides), empty = worldwide as a
    /// deliberate choice. The two states must stay distinguishable.
    static let radioGenreCountryCodes = "radioGenreCountryCodes"
    /// The free-catalog mix of the LAST session. The next start
    /// gives these a malus so the shuffle cannot deal the same trio again.
    static let catalogMixLastShown = "catalogMixLastShown"

    /// Artist portraits from open sources (MB→Wikidata→Commons; opt-out.
    /// Server images always win, off just means color circles).
    static let musicArtistImagesOnline = "musicArtistImagesOnline"
    static var musicArtistImagesOnlineValue: Bool {
        get { UserDefaults.standard.object(forKey: musicArtistImagesOnline) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicArtistImagesOnline) }
    }

    /// Radio: the ONE user-chosen state for the region section (nil = not
    /// chosen; chosen once, persisted. No location permission, ever).
    static let radioRegionState = "radioRegionState"

    /// Listen log: one-time backfill of the current subscriptions done.
    static let listenLogBackfilled = "listenLogBackfilled"

    /// gpodder: the deviceId this install has REGISTERED on the server
    /// (one-shot per id; the id itself is never re-rolled for existing users).
    static let gpodderDeviceRegisteredFor = "gpodderDeviceRegisteredFor"

    /// LRCLIB lyrics lookup (opt-out; server lyrics always win).
    static let musicLyricsOnlineLookup = "musicLyricsOnlineLookup"
    static var musicLyricsOnlineLookupValue: Bool {
        get { UserDefaults.standard.object(forKey: musicLyricsOnlineLookup) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicLyricsOnlineLookup) }
    }

    /// High-res covers from the Cover Art Archive (opt-out).
    static let musicHighResCovers = "musicHighResCovers"
    static var musicHighResCoversValue: Bool {
        get { UserDefaults.standard.object(forKey: musicHighResCovers) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicHighResCovers) }
    }

    static var subsonicConfigured: Bool {
        !subsonicServerURLValue.isEmpty && !subsonicUsernameValue.isEmpty && !subsonicPasswordValue.isEmpty
    }

    /// ABS as a podcast source only when explicitly enabled (default OFF). The
    /// ABS server is primarily an audiobook server; it must not assume podcasts
    /// exist just because a podcast library is present.
    static let absPodcastsEnabled = "absPodcastsEnabled"
    /// Queued ABS played-writes that failed offline (itemId → played).
    static let absPendingPlayedWrites = "absPendingPlayedWrites"
    static var absPodcastsEnabledValue: Bool {
        get { UserDefaults.standard.bool(forKey: absPodcastsEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: absPodcastsEnabled) }
    }

    /// gpodder ↔ ABS-podcasts are mutually exclusive (one external podcast SERVER
    /// at a time; RSS is separate and untouched). Set the two ONLY through these
    /// so the rule lives in one place (`PodcastServerExclusivity`).
    /// Returns true when the OTHER source was just turned off (UI can note it).
    @discardableResult
    static func setGpodderEnabled(_ on: Bool) -> Bool {
        let absWasOn = absPodcastsEnabledValue
        let r = PodcastServerExclusivity.resolved(gpodder: on, abs: absWasOn, changed: .gpodder)
        gpodderEnabledValue = r.gpodder
        absPodcastsEnabledValue = r.abs
        return absWasOn && !r.abs
    }
    @discardableResult
    static func setABSPodcastsEnabled(_ on: Bool) -> Bool {
        let gpodderWasOn = gpodderEnabledValue
        let r = PodcastServerExclusivity.resolved(gpodder: gpodderWasOn, abs: on, changed: .abs)
        gpodderEnabledValue = r.gpodder
        absPodcastsEnabledValue = r.abs
        return gpodderWasOn && !r.gpodder
    }

    // MARK: - Library toggles (TF bib-toggles): two levels. Tab master + source

    /// Tab masters (whole media type on/off). Default ON so existing installs
    /// keep every tab; `object ?? true` because `bool(forKey:)` defaults false.
    /// Letzter-Tab (01.08): the app starts on the last selected tab again
    /// (user expectation since the podcast-tab diagnosis; Home stays the
    /// default for fresh installs).
    static let lastSelectedTab = "lastSelectedTab"
    static var lastSelectedTabValue: String? {
        get { UserDefaults.standard.string(forKey: lastSelectedTab) }
        set { UserDefaults.standard.set(newValue, forKey: lastSelectedTab) }
    }

    static let audiobooksTabEnabled = "audiobooksTabEnabled"
    static let podcastsTabEnabled = "podcastsTabEnabled"
    static let musicTabEnabled = "musicTabEnabled"
    static let radioTabEnabled = "radioTabEnabled"
    static var audiobooksTabEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: audiobooksTabEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audiobooksTabEnabled) }
    }
    static var podcastsTabEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: podcastsTabEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: podcastsTabEnabled) }
    }
    static var musicTabEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: musicTabEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicTabEnabled) }
    }
    static var radioTabEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: radioTabEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: radioTabEnabled) }
    }

    /// Per-source toggles that were missing (ABS-audiobooks, RSS). Default ON.
    /// They only surface content when there IS content anyway (token / feeds).
    /// (Subsonic, ABS-podcasts and Radio already have their own toggles above.)
    static let absAudiobooksEnabled = "absAudiobooksEnabled"
    static let rssEnabled = "rssEnabled"
    static var absAudiobooksEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: absAudiobooksEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: absAudiobooksEnabled) }
    }
    static var rssEnabledValue: Bool {
        get { UserDefaults.standard.object(forKey: rssEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rssEnabled) }
    }

    /// The same class as the catalog defaults, here for preferences: the
    /// default value stood at several reading sites. It stands in ONE place
    /// now, so the fence needs no exceptions.
    nonisolated static var smartRewindValue: Bool { boolValue(smartRewind) }
    nonisolated static var warnCellularDownloadValue: Bool { boolValue(warnCellularDownload) }
    nonisolated static let podcastAutoSaveOnPlay = "podcastAutoSaveOnPlay"
    nonisolated static var podcastAutoSaveOnPlayValue: Bool { boolValue(podcastAutoSaveOnPlay) }
    /// Create new subscriptions ON the Audiobookshelf server instead of only
    /// locally. It was `@State` and therefore forgot itself the moment the
    /// page closed. Whoever switched it off had server subscriptions again
    /// on the next visit. Default stays `true`: that is the behaviour every
    /// session had so far, and a different one would be a silent change for
    /// existing users.
    nonisolated static let podcastSubscribeToServer = "podcastSubscribeToServer"
    /// Feeds that arrived over iCloud and answered the adoption with a
    /// sign-in demand: feed key ⇒ address, kept until a login is saved or
    /// the person removes them. Device-class: the login lives here.
    nonisolated static let podcastFeedsNeedingSignIn = "podcastFeedsNeedingSignIn"
    /// Feed keys the person subscribed here while Audiobookshelf could not
    /// be read; the next read settles them against the server. Machine
    /// state of this device: what it could not read.
    nonisolated static let podcastServerUncheckedFeeds = "podcastServerUncheckedFeeds"
    /// Refused refreshes per subscribed feed (`FeedRefusal`): feed key ⇒
    /// count, first, latest, status. Device-class: every device measures
    /// its own access.
    nonisolated static let podcastFeedRefusals = "podcastFeedRefusals"
    /// The free feed of a paid show (`FreeTwin`), where the app saw it: the
    /// free subscription that gave way to the paid one, or the free twin an
    /// import skipped. `podcastFreeTwin.<paid show id>` ⇒ address, never a
    /// credential. Travels: the address is the same on every device.
    nonisolated static func podcastFreeTwin(_ showId: String) -> String { "podcastFreeTwin.\(showId)" }
    /// The one directory search per refused paid show: show id ⇒ `[address,
    /// title]` or `[]` for nothing found. A failed search leaves nothing.
    /// Device-class: every device asks its own directory.
    nonisolated static let podcastFreeTwinSearched = "podcastFreeTwinSearched"
    /// Shows whose switch offer the person answered with No, on this device.
    nonisolated static let podcastFreeTwinDeclined = "podcastFreeTwinDeclined"
    /// The paid address a show left for its free twin: free show id ⇒ paid
    /// address. Device-class: the address carries the access token.
    nonisolated static let podcastPaidTwin = "podcastPaidTwin"

    // MARK: - Katalog-Aktivierung

    /// The eight free catalog sources carried a SECOND, hand-written
    /// activation system in exactly the shape of the modelled one: master
    /// switch ∧ individual switch, only without a model. The default stood
    /// 35 times in eleven files and every reading site composed it itself.
    /// All 35 agreed, and nothing enforced that.
    ///
    /// Catalogs follow the same rule as server sources: ONE answer per
    /// source about its state, in ONE place. Since the sources/rows rebuild
    /// there are exactly two questions (source allowed, row visible) and no
    /// overriding level.
    nonisolated static func boolValue(_ key: String, default defaultValue: Bool = true) -> Bool {
        boolValue(key, in: .standard, default: defaultValue)
    }

    /// The same ONE reading place, with an injectable store for tests. The
    /// literal fallback lives here and nowhere else.
    nonisolated static func boolValue(_ key: String, in defaults: UserDefaults,
                                      default defaultValue: Bool = true) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// The old three-level activation is GONE. What produced switches that
    /// said "on" and did nothing was the third, overriding level; since the
    /// migration below there are exactly two questions left, and every
    /// property here is a composition of them:
    ///
    ///     source allowed: may the app ask this foreign service
    ///     row visible:    does this tile row appear
    ///
    /// The names stay so the forty-odd read sites keep reading; what they
    /// mean is now honest.
    nonisolated static var archiveServiceActive: Bool {
        ExternalSources.isAllowed(ExternalSources.internetArchive)
    }
    nonisolated static var librivoxActive: Bool {
        ExternalSources.isAllowed(ExternalSources.librivox)
    }
    nonisolated static var gutenbergSourceActive: Bool {
        ExternalSources.isAllowed(ExternalSources.gutenberg)
    }
    nonisolated static var archiveBooksActive: Bool {
        ExternalSources.isAllowed(ExternalSources.internetArchive)
    }
    nonisolated static var jamendoActive: Bool {
        ExternalSources.isAllowed(ExternalSources.jamendo)
    }
    /// The classical half of Start's music discovery. It is shown there
    /// alone, so it follows that row's switch, not the music tab's old
    /// records. The old key stays declared but unread: a new key would
    /// silently reset the setting of every user.
    nonisolated static var freeClassicalActive: Bool {
        ExternalSources.isAllowed(ExternalSources.internetArchive)
            && AppRows.row(key: "home.discoverMusic").map { AppRows.isVisible($0) } ?? true
    }
    nonisolated static var netlabelsActive: Bool {
        ExternalSources.isAllowed(ExternalSources.internetArchive)
            && AppRows.row(key: "music.netlabels").map { AppRows.isVisible($0) } ?? true
    }
    nonisolated static var shellacActive: Bool {
        ExternalSources.isAllowed(ExternalSources.internetArchive)
            && AppRows.row(key: "music.oldRecords").map { AppRows.isVisible($0) } ?? true
    }
    nonisolated static var freeAudiobooksAreaActive: Bool {
        AppRows.row(key: "books.catalog").map { AppRows.isVisible($0) } ?? true
    }

    /// Pinchflat was the ONLY one of the fourteen sources without an on/off
    /// switch. It belonged to neither of the two activation systems, so
    /// nobody noticed it had none. In practice: every other source can be
    /// shut down WITHOUT removing it, credentials included, while Pinchflat
    /// left only deletion and afterwards re-entering address and token.
    static let pinchflatEnabled = "pinchflatEnabled"
    /// This source's switch ALONE, without the tab. It has a name of its
    /// own as with the other sources, because a message that names the
    /// switch must mean exactly it and not the sum.
    static var pinchflatEnabledValue: Bool { boolValue(pinchflatEnabled) }
    static var pinchflatActive: Bool {
        SourceActivation.effective(tabEnabled: podcastsTabEnabledValue,
                                   sourceEnabled: pinchflatEnabledValue)
    }

    /// Effective activation per source = tab master ∧ source toggle (the one
    /// invariant, `SourceActivation.effective`). Providers gate ALL their calls
    /// and their tab visibility on these.
    static var absAudiobooksActive: Bool {
        SourceActivation.effective(tabEnabled: audiobooksTabEnabledValue, sourceEnabled: absAudiobooksEnabledValue)
    }
    static var absPodcastsActive: Bool {
        SourceActivation.effective(tabEnabled: podcastsTabEnabledValue, sourceEnabled: absPodcastsEnabledValue)
    }
    static var rssActive: Bool {
        SourceActivation.effective(tabEnabled: podcastsTabEnabledValue, sourceEnabled: rssEnabledValue)
    }
    /// Does the Subsonic source feed THIS type? The pair says what the user
    /// asked for, the library rule says what can actually be delivered, and the
    /// tab gate says whether the type is on at all. The middle term keeps a
    /// surface from promising what it cannot deliver: a second mode without its own library is never a tab, it is a
    /// visible gap on the source page.
    static func subsonicActive(for type: MediaType) -> Bool {
        let modes = subsonicModes
        guard SourceLibraries.serves(type, modes: modes,
                                     known: subsonicKnownLibraries,
                                     assignment: subsonicAssignment) else { return false }
        return SourceActivation.effective(
            tabEnabled: tabEnabledValue(for: type),
            sourceEnabled: subsonicEnabledValue)
    }

    /// Whether the source is live at all. The gate the CLIENT hangs on, and
    /// NOT the sum of the per-type answers. A source that serves NO type serves
    /// nothing; that is an activation statement, not a content type, which is
    /// why it is answered here and not as a third value in the pair.
    static var subsonicActive: Bool {
        SourceLibraries.isLive(
            modes: subsonicModes,
            enabled: subsonicEnabledValue,
            enabledTabs: Set(MediaType.allCases.filter(tabEnabledValue(for:))))
    }

    /// The tab switch of a type. Radio and podcasts are listed for
    /// completeness; no server source claims them through this gate.
    static func tabEnabledValue(for type: MediaType) -> Bool {
        switch type {
        case .audiobooks: return audiobooksTabEnabledValue
        case .music:      return musicTabEnabledValue
        case .podcasts:   return podcastsTabEnabledValue
        case .radio:      return radioTabEnabledValue
        case .home:       return true
        }
    }
    /// Does the Jellyfin source feed THIS type? Unlike Subsonic, nothing is
    /// assigned here: the server names the kind of each library itself, so the
    /// pair is derived from the books library it reported, and the tab gate
    /// answers the rest. A server without a books library serves music only.
    static func jellyfinActive(for type: MediaType) -> Bool {
        let modes = SourceModes.fromServerNamedLibraries(
            hasBooksLibrary: !jellyfinBooksViewIdValue.isEmpty)
        guard modes.serves(type) else { return false }
        return SourceActivation.effective(
            tabEnabled: tabEnabledValue(for: type),
            sourceEnabled: jellyfinEnabledValue)
    }

    /// Whether the source is live at all, the gate the CLIENT hangs on. Same
    /// shape as `subsonicActive`: a source that serves no type serves nothing.
    static var jellyfinActive: Bool {
        MediaType.allCases.contains { jellyfinActive(for: $0) }
    }
    static var radioActive: Bool {
        SourceActivation.effective(tabEnabled: radioTabEnabledValue, sourceEnabled: radioEnabledValue)
    }
    /// Is there a music SERVER behind the music surfaces? Everything that
    /// offers a server-side action asks THIS. The composed answer lives here
    /// like the other source gates, not as a copied `||` per surface.
    static var musicServerActive: Bool {
        subsonicActive(for: .music) || jellyfinActive(for: .music)
    }

    /// Notify about new podcast episodes (background refresh). Opt-in.
    static let podcastNewEpisodeNotifications = "podcastNewEpisodeNotifications"
    static var podcastNewEpisodeNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: podcastNewEpisodeNotifications)
    }

    /// Whether anything at all travels between the person's own devices.
    ///
    /// ONE switch, and the reason it is one has CHANGED. It used to be the
    /// shared 1 MB of `NSUbiquitousKeyValueStore`: progress and playlists
    /// wrote into the same budget, so two switches would have suggested an
    /// independence that did not exist. Since 3.0 that no longer holds.
    /// Four of the five sorts travel over their own CloudKit zone or over
    /// the Mär sync service, and with a service set up no Apple carrier is
    /// built at all. The switch stays one because the DECISION is one: a
    /// person decides whether their devices know about each other, not
    /// which transport carries which sort. The transport follows from what
    /// is set up.
    ///
    /// The key keeps the old name deliberately. Renaming it resets the
    /// setting of every existing user to the default, invisibly.
    static let podcastICloudSync = "podcastICloudSync"
    /// The raw reading, for the carriers that really mean Apple.
    static var podcastICloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: podcastICloudSync) as? Bool ?? true
    }
    /// The SAME setting, under the name of the question it answers
    /// everywhere above a carrier: does anything travel between this
    /// person's devices.
    ///
    /// The two names exist because the old one misled a reader who had
    /// every reason to trust it: a key called `podcastICloudSync` read at
    /// the top of the claim runner says "this depends on iCloud", and the
    /// runner sits above all carriers, so it does not. The value is the
    /// same value, so nothing changes for anyone; only the sentence at the
    /// reading site is true now. `PodcastICloudSwitchFenceTests` holds
    /// which site may read which name.
    static var syncAcrossDevicesEnabled: Bool { podcastICloudSyncEnabled }
    /// When iCloud last refused a write because the shared 1 MB is exhausted.
    /// Kept because the failure is otherwise INVISIBLE: the store simply stops
    /// accepting writes, no call site sees an error, and two devices drift
    /// apart for weeks. The diagnosis surface reads this.
    nonisolated static let cloudQuotaViolationAt = "cloudQuotaViolationAt"
    nonisolated static func noteCloudQuotaViolation(in defaults: UserDefaults = .standard) {
        defaults.set(Date().timeIntervalSince1970, forKey: cloudQuotaViolationAt)
    }
    nonisolated static func cloudQuotaViolation(in defaults: UserDefaults = .standard) -> Date? {
        let stamp = defaults.double(forKey: cloudQuotaViolationAt)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    static let lastPlayedItemId = "lastPlayedItemId"
    static let pendingDownloadDestinations = "pendingDownloadDestinations"
    /// The Audiobookshelf server signed in now and the server of the last
    /// full library load, as normalized addresses, and when the signed-in
    /// server last changed (ms). `ABSServerScope` decides on them.
    static let absSignedInServer = "absSignedInServer"
    static let absLastFullLoadServer = "absLastFullLoadServer"
    static let absServerSwitchedAt = "absServerSwitchedAt"
    /// Set once a sign-in moved from one known server to another; then no
    /// full load cleans ids without a namespace (`ABSServerScope.cleanup`).
    static let absMoreThanOneServer = "absMoreThanOneServer"

    /// Notes a sign-in at `server`. Another server than the one signed in
    /// before is a switch, and so is the first sign-in the device
    /// remembers: a switch only keeps queued stands, never drops one. A
    /// move from one known server to another marks the device as having
    /// known more than one.
    static func noteABSSignIn(_ server: String, nowMs: Double) {
        let before = string(absSignedInServer)
        if before != server { set(nowMs, for: absServerSwitchedAt) }
        if let before, before != server { set(true, for: absMoreThanOneServer) }
        set(server, for: absSignedInServer)
    }
    /// Per-item markers for "don't show under Continue any more"
    /// (the listening position stays untouched).
    static let continueHiddenMarkers = "continueHiddenMarkers"
    /// Feed keys of co-listened shows the user took out of "Latest Episodes".
    static let coListenedHidden = "coListenedHidden"
    /// "Next steps" was dismissed once; until then the card returns at every start.
    static let nextStepsDismissed = "nextStepsDismissed"
    /// Sources an import already brought something from (guide ticks).
    static let foreignImportsDone = "foreignImportsDone"
    static let librarySortOption = "librarySortOption"
    static let libraryFilterOption = "libraryFilterOption"
    static let librarySortAscending = "librarySortAscending"
    // Teil 2: per-tab sort/filter (audiobooks reuse the library* keys above).
    static let podcastSortOption = "podcastSortOption"
    static let podcastFilterOption = "podcastFilterOption"
    static let musicSortOption = "musicSortOption"
    /// The clock duration the sleep timer was last started with. Whoever sets
    /// the same thirty minutes every evening should find them at the top
    /// instead of aiming at the same row again.
    ///
    /// Only the CLOCK durations are remembered: "until end of chapter" and
    /// "until end of track" are not a duration and mean something different
    /// on every item.
    static let sleepTimerLastMinutes = "sleepTimerLastMinutes"
    /// Nothing remembered yet reads as zero, and zero is not an offer.
    static var sleepTimerRemembered: Double? {
        let stored = UserDefaults.standard.double(forKey: sleepTimerLastMinutes)
        return stored > 0 ? stored : nil
    }
    static func rememberSleepTimer(minutes: Double) {
        guard minutes > 0 else { return }
        UserDefaults.standard.set(minutes, forKey: sleepTimerLastMinutes)
    }

    static func playbackRate(_ itemId: String) -> String { "playbackRate.\(itemId)" }
    static func localPosition(_ itemId: String) -> String { "localPosition.\(itemId)" }
    /// What THIS device last pushed successfully, and when.
    /// `[time, atMs]`. Its own key on purpose: `localPosition` is the crash
    /// backup with its own reader group, and a changed shape there would need
    /// a full sweep. The two facts are also different: the backup is a value
    /// the server never saw, this one is a value the server already had.
    static func flushedPosition(_ itemId: String) -> String { "flushedPosition.\(itemId)" }
    /// The last few backward jumps of this book. The diagnosis
    /// is the only window the person has, system logs are not practical.
    /// The ring's keys go with their book (`cleanupPerBookKeys`).
    static func jumpRing(_ itemId: String) -> String { "jumpRing.\(itemId)" }

    /// Per-show playback speed (start rate for this show's episodes until an
    /// episode has its own saved rate).
    static func podcastShowRate(_ showId: String) -> String { "podcastShowRate.\(showId)" }

    /// The ONE writer of a show's playback rate: a person's choice that
    /// travels, so it goes through the noted path like the other per-show
    /// settings. The change guard keeps the settings sheet's onChange from
    /// stamping "now" while it fills its own fields.
    @MainActor static func setPodcastShowRate(_ rate: Float?, showId: String) {
        let key = podcastShowRate(showId)
        let current = UserDefaults.standard.object(forKey: key) as? Float
        guard current != rate else { return }
        if let rate { UserDefaults.standard.set(rate, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        UserChoiceCloudSync.shared.noteScalar(key: key, value: rate)
    }

    // MARK: - Per-show behaviour (inbox / notification)

    /// The number on every show tile, app-wide: all unplayed (standard),
    /// new since the last one played, or off. Not to be confused with the
    /// per-show inbox mode below, which governs which new episodes reach
    /// the inbox and notifications.
    static let podcastTileCountMode = PodcastTileCount.storageKey

    /// "New episodes" mode per show: "all" | "latest" | "off". A show without
    /// its own follows the value for all shows (default all).
    static func podcastInboxMode(_ showId: String) -> String { "podcastInboxMode.\(showId)" }
    static func podcastInboxModeValue(_ showId: String) -> String {
        PodcastGeneralRule.effective(stored: storedPodcastInboxMode(showId), general: podcastInboxModeGeneral)
    }
    static func storedPodcastInboxMode(_ showId: String) -> String? {
        UserDefaults.standard.string(forKey: podcastInboxMode(showId))
    }
    /// "New episodes" for all shows. Travels like the per-show value.
    static let podcastInboxModeAll = "podcastInboxModeAll"
    static var podcastInboxModeGeneral: String {
        UserDefaults.standard.string(forKey: podcastInboxModeAll) ?? "all"
    }
    /// The direction the automatic download reads this show in. It travels;
    /// its reader and writer is `PodcastAutoDownload`.
    static func podcastAutoDownloadDirection(_ showId: String) -> String { "podcastAutoDownloadDirection.\(showId)" }
    /// Notify about new episodes of this show (default on; only takes effect
    /// when the global notification is enabled).
    static func podcastNotify(_ showId: String) -> String { "podcastNotify.\(showId)" }
    static func podcastNotifyEnabled(_ showId: String) -> Bool {
        UserDefaults.standard.object(forKey: podcastNotify(showId)) as? Bool ?? true
    }
    // Guarded setters: write + note into the choice family only on a real
    // change. The settings sheet's `onChange` also fires when `onAppear`
    // fills the state. An unguarded note there would stamp a fresh event
    // time on every sheet visit and stomp the other device.
    @MainActor
    static func setPodcastInboxMode(_ mode: String, showId: String) {
        guard podcastInboxModeValue(showId) != mode else { return }
        writeChoice(mode, key: podcastInboxMode(showId))
    }
    @MainActor
    static func setPodcastNotify(_ enabled: Bool, showId: String) {
        guard podcastNotifyEnabled(showId) != enabled else { return }
        writeChoice(enabled, key: podcastNotify(showId))
    }

    /// The value for all shows, and the one way a show's own value goes, so
    /// it follows again. Both travel; a removal as a tombstone.
    @MainActor
    static func setPodcastInboxModeGeneral(_ mode: String) {
        guard podcastInboxModeGeneral != mode else { return }
        writeChoice(mode, key: podcastInboxModeAll)
    }
    @MainActor
    static func clearPodcastInboxMode(showId: String) {
        guard storedPodcastInboxMode(showId) != nil else { return }
        writeChoice(nil, key: podcastInboxMode(showId))
    }

    /// The one write of a travelling per-show or all-shows choice: the
    /// store, then the note into the choice family. Nil removes and travels
    /// as a tombstone.
    @MainActor
    private static func writeChoice(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        noteChoice(value, key: key)
    }

    /// The note half alone, for a writer whose own rule already stored the
    /// value (a show page's sort and filter, written only in the subscribed
    /// state). Nil travels as a tombstone.
    @MainActor
    static func noteChoice(_ value: Any?, key: String) {
        UserChoiceCloudSync.shared.noteScalar(key: key, value: value)
    }

    /// Derive the show id from a podcast episode id (`rss:<key>:<guid>` →
    /// `rss:<key>`, `abspod:<item>:<ep>` → `abspod:<item>`). Feed key/item id
    /// contain no `:`, so the first two segments are the show id.
    static func podcastShowId(forEpisodeId id: String) -> String? {
        guard ItemNamespace.isPodcastEpisode(id) else { return nil }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ":")
    }

    /// Removes per-book entries for books that no longer exist. Only call with a
    /// FULL library list (never the filtered offline list. Valid keys would be
    /// dropped otherwise).
    static func cleanupPerBookKeys(validItemIds: Set<String>, in defaults: UserDefaults = .standard) {
        let gone: (String) -> Bool = { prunedByBookCleanup($0, validItemIds: validItemIds) }
        for prefix in ["playbackRate.", PlayedTail.prefix] {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                if gone(String(key.dropFirst(prefix.count))) { defaults.removeObject(forKey: key) }
            }
        }
        // Positions through their store, so its stock and the row copy follow.
        ListeningStore.forgetBackups(where: gone, in: defaults)
    }

    /// Whether the audiobook cleanup may remove a title's keys: only a raw
    /// library id, one WITHOUT a namespace, that the fully loaded library no
    /// longer holds. `validItemIds` names audiobooks only, so an id of any
    /// other source (a song, a catalog title, an episode, a namespace that
    /// does not exist yet) is never the cleanup's to judge.
    nonisolated static func prunedByBookCleanup(_ id: String, validItemIds: Set<String>) -> Bool {
        ItemNamespace.of(id) == nil && !validItemIds.contains(id)
    }

    /// Whether a fully loaded list may judge the books at all. The list
    /// holds ONE library; with a second book library on the server its
    /// books are absent from the list, not gone, and their positions,
    /// speeds and bookmarks must stay. An unknown number of libraries
    /// knows nothing either.
    nonisolated static func listJudgesEveryBook(bookLibraries: Int?) -> Bool {
        bookLibraries == 1
    }

}
