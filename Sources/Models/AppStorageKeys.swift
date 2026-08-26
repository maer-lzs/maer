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
    /// build-injected app key (`ABSPlayer-Info.plist`, values via
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
    /// Opt-in PER gpodder account. "private server: sync premium
    /// feeds too". Default OFF = the Y52 rule unchanged (token feeds never
    /// leave the device). The rationale for the switch existing at all: for
    /// a self-hoster their own oPodSync IS the trusted place of the vision;
    /// the Y52 lock protects the FOREIGN-server case (gpodder.net), not the
    /// own one. Pinchflat mirrors stay out either way. Their reason is
    /// reachability, not secrecy.
    static let gpodderSyncsPremiumFeeds = "gpodderSyncsPremiumFeeds"
    nonisolated static var gpodderSyncsPremiumFeedsEnabled: Bool {
        UserDefaults.standard.bool(forKey: gpodderSyncsPremiumFeeds)
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

    // MARK: - Radio (F1)

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

    nonisolated static var subsonicKnownLibraries: [SourceLibrary] {
        get {
            guard let data = UserDefaults.standard.data(forKey: subsonicLibraries),
                  let list = try? JSONDecoder().decode([SourceLibrary].self, from: data)
            else { return [] }
            return list
        }
        set {
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
    /// Die Schellack-Flaeche (78 rpm genre shelves, georgeblood).
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
    /// MASTER switch over every free-catalog surface + its traffic.
    static let freeCatalogsMasterEnabled = "freeCatalogsMasterEnabled"
    /// The "Free Audiobooks" AREA toggle. It lives at the "Free
    /// Catalogs" area of the source map (it used to sit in the audiobooks
    /// pill); the LibriVox service opt-out stays superior.
    static let freeAudiobooksEnabled = "freeAudiobooksEnabled"

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
    nonisolated static var podcastSubscribeToServerValue: Bool {
        boolValue(podcastSubscribeToServer)          // default true, wie bisher
    }

    // MARK: - Katalog-Aktivierung

    /// The eight free catalog sources carried a SECOND, hand-written
    /// activation system in exactly the shape of the modelled one: master
    /// switch ∧ individual switch, only without a model. The default stood
    /// 35 times in eleven files and every reading site composed it itself.
    /// All 35 agreed, and nothing enforced that.
    ///
    /// Catalogs now follow the same rule as server sources: ONE answer per
    /// source about its state, in ONE place, through the same pure rule. The
    /// three levels stay as they were (master > area > service).
    /// `FreeCatalogActivation.effective` is the pure function for it.
    nonisolated static func boolValue(_ key: String, default defaultValue: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    /// The master switch above all catalog surfaces.
    nonisolated static var freeCatalogsMasterActive: Bool { boolValue(freeCatalogsMasterEnabled) }
    /// The archive.org SERVICE opt-out, above the three archive surfaces.
    nonisolated static var archiveServiceActive: Bool {
        freeCatalogsMasterActive && boolValue(archivePopularEnabled)
    }

    // These three switches are SERVICES (whom does the app contact), not
    // areas. So they are passed as `service:`. The result is the same either
    // way (both sides are ANDed), but the call now says which of the two a
    // switch is, and that is the distinction the placement rule rests on.
    nonisolated static var librivoxActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: true, service: boolValue(librivoxRowsEnabled))
    }
    nonisolated static var archiveBooksActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: true, service: boolValue(archivePopularEnabled))
    }
    nonisolated static var jamendoActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: true, service: boolValue(jamendoRowEnabled))
    }
    /// Classical is a shelf of the 78rpm records now, not an area of its own.
    /// It follows their switch. The old key stays declared but unread: a new
    /// key would silently reset the setting of every user.
    nonisolated static var freeClassicalActive: Bool { shellacActive }
    nonisolated static var netlabelsActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: boolValue(netlabelsRowEnabled),
                                        service: boolValue(archivePopularEnabled))
    }
    nonisolated static var shellacActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: boolValue(shellacRowsEnabled),
                                        service: boolValue(archivePopularEnabled))
    }
    nonisolated static var freeAudiobooksAreaActive: Bool {
        FreeCatalogActivation.effective(master: freeCatalogsMasterActive,
                                        feature: boolValue(freeAudiobooksEnabled), service: true)
    }
    nonisolated static var radioLogoChainActive: Bool { boolValue(radioLogoChainEnabled) }

    /// Pinchflat was the ONLY one of the fourteen sources without an on/off
    /// switch. It belonged to neither of the two activation systems, so
    /// nobody noticed it had none. In practice: every other source can be
    /// shut down WITHOUT removing it, credentials included, while Pinchflat
    /// left only deletion and afterwards re-entering address and token.
    static let pinchflatEnabled = "pinchflatEnabled"
    static var pinchflatActive: Bool {
        SourceActivation.effective(tabEnabled: podcastsTabEnabledValue,
                                   sourceEnabled: boolValue(pinchflatEnabled))
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
    /// tab gate says whether the type is on at all. G8 lives in the middle
    /// term: a second mode without its own library is never a tab, it is a
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
    static var jellyfinActive: Bool {
        SourceActivation.effective(tabEnabled: musicTabEnabledValue, sourceEnabled: jellyfinEnabledValue)
    }
    static var radioActive: Bool {
        SourceActivation.effective(tabEnabled: radioTabEnabledValue, sourceEnabled: radioEnabledValue)
    }
    /// Is there a music SERVER behind the music surfaces? Everything that
    /// offers a server-side action asks THIS. The composed answer lives here
    /// like the other source gates, not as a copied `||` per surface.
    static var musicServerActive: Bool { subsonicActive || jellyfinActive }

    /// Notify about new podcast episodes (background refresh). Opt-in.
    static let podcastNewEpisodeNotifications = "podcastNewEpisodeNotifications"
    static var podcastNewEpisodeNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: podcastNewEpisodeNotifications)
    }

    /// Sync podcast progress across your own devices via iCloud.
    /// ONE iCloud switch for podcast progress AND Mär playlists: both write
    /// into the same `NSUbiquitousKeyValueStore` with its shared 1 MB budget,
    /// so two switches would suggest an independence that does not exist. The
    /// key keeps the old name deliberately. Renaming it resets the setting of
    /// every existing user to the default, invisibly.
    static let podcastICloudSync = "podcastICloudSync"
    static var podcastICloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: podcastICloudSync) as? Bool ?? true
    }
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
    /// Per-item markers for "don't show under Continue any more"
    /// (the listening position stays untouched).
    static let continueHiddenMarkers = "continueHiddenMarkers"
    static let librarySortOption = "librarySortOption"
    static let libraryFilterOption = "libraryFilterOption"
    static let librarySortAscending = "librarySortAscending"
    // Teil 2: per-tab sort/filter (audiobooks reuse the library* keys above).
    static let podcastSortOption = "podcastSortOption"
    static let podcastFilterOption = "podcastFilterOption"
    static let musicSortOption = "musicSortOption"
    static let downloadExtensionRepairDone = "downloadExtensionRepairV2"
    static let downloadDeepValidationDone = "downloadDeepValidationV1"

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
    static func jumpRing(_ itemId: String) -> String { "jumpRing.\(itemId)" }

    /// Per-show playback speed (start rate for this show's episodes until an
    /// episode has its own saved rate).
    static func podcastShowRate(_ showId: String) -> String { "podcastShowRate.\(showId)" }

    // MARK: - Per-show behaviour (inbox / notification / trimming)

    /// "New episodes" mode per show: "all" | "latest" | "off" (default all).
    static func podcastInboxMode(_ showId: String) -> String { "podcastInboxMode.\(showId)" }
    static func podcastInboxModeValue(_ showId: String) -> String {
        UserDefaults.standard.string(forKey: podcastInboxMode(showId)) ?? "all"
    }
    /// Notify about new episodes of this show (default on; only takes effect
    /// when the global notification is enabled).
    static func podcastNotify(_ showId: String) -> String { "podcastNotify.\(showId)" }
    static func podcastNotifyEnabled(_ showId: String) -> Bool {
        UserDefaults.standard.object(forKey: podcastNotify(showId)) as? Bool ?? true
    }
    /// Keep only the latest N episodes of this show (0 = unlimited).
    static func podcastEpisodeLimit(_ showId: String) -> String { "podcastEpisodeLimit.\(showId)" }
    static func podcastEpisodeLimitValue(_ showId: String) -> Int {
        UserDefaults.standard.integer(forKey: podcastEpisodeLimit(showId))
    }

    // Guarded setters: write + note into the choice family only on a real
    // change. The settings sheet's `onChange` also fires when `onAppear`
    // fills the state. An unguarded note there would stamp a fresh event
    // time on every sheet visit and stomp the other device.
    @MainActor
    static func setPodcastInboxMode(_ mode: String, showId: String) {
        guard podcastInboxModeValue(showId) != mode else { return }
        UserDefaults.standard.set(mode, forKey: podcastInboxMode(showId))
        UserChoiceCloudSync.shared.noteScalar(key: podcastInboxMode(showId), value: mode)
    }
    @MainActor
    static func setPodcastNotify(_ enabled: Bool, showId: String) {
        guard podcastNotifyEnabled(showId) != enabled else { return }
        UserDefaults.standard.set(enabled, forKey: podcastNotify(showId))
        UserChoiceCloudSync.shared.noteScalar(key: podcastNotify(showId), value: enabled)
    }
    @MainActor
    static func setPodcastEpisodeLimit(_ limit: Int, showId: String) {
        guard podcastEpisodeLimitValue(showId) != limit else { return }
        UserDefaults.standard.set(limit, forKey: podcastEpisodeLimit(showId))
        UserChoiceCloudSync.shared.noteScalar(key: podcastEpisodeLimit(showId), value: limit)
    }

    /// Derive the show id from a podcast episode id (`rss:<key>:<guid>` →
    /// `rss:<key>`, `abspod:<item>:<ep>` → `abspod:<item>`). Feed key/item id
    /// contain no `:`, so the first two segments are the show id.
    static func podcastShowId(forEpisodeId id: String) -> String? {
        guard id.hasPrefix("rss:") || id.hasPrefix("abspod:") else { return nil }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ":")
    }

    /// Removes per-book entries for books that no longer exist. Only call with a
    /// FULL library list (never the filtered offline list. Valid keys would be
    /// dropped otherwise).
    static func cleanupPerBookKeys(validItemIds: Set<String>) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["playbackRate.", "localPosition."] where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                // Only prune raw ABS book ids. Podcast/local keys
                // (`rss:`/`abspod:`/`local:`) belong to other sources with their
                // own lifecycle. `validItemIds` holds audiobooks only, so all
                // podcast/local progress would be deleted here otherwise.
                if id.hasPrefix("rss:") || id.hasPrefix("abspod:") || id.hasPrefix("local:") {
                    continue
                }
                if !validItemIds.contains(id) {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

}
