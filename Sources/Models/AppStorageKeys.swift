// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Central place for all UserDefaults keys. Per-book keys are pruned via
/// `cleanupPerBookKeys` once a book no longer exists in the (full) library.
// nonisolated: pure key helpers, must be callable from background tasks
// (the project uses default MainActor isolation).
nonisolated enum AppStorageKeys {
    static let skipInterval = "skipInterval"
    /// X24: last bottom-bar cover accent (RGBA components) — restored at launch
    /// so the bar never falls back to neutral once an item has ever played.
    static let bottomBarAccent = "bottomBarAccent"
    /// Teil 5: ONE opt-out for the Home recommendation sections (Rediscover +
    /// Discover); default on.
    static let homeRecommendations = "homeRecommendations"
    /// Speed for books that have no per-book rate saved yet.
    static let defaultPlaybackRate = "defaultPlaybackRate"
    /// Resume slightly earlier after a longer pause (default ON).
    static let smartRewind = "smartRewind"
    /// "system" | "light" | "dark" — overrides the system appearance.
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
    /// Old UserDefaults key of the secret — kept only for the one-time
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

    static var podcastIndexConfigured: Bool {
        !podcastIndexKeyValue.isEmpty && !podcastIndexSecretValue.isEmpty
    }
    // MARK: - gpodder / oPodSync (open podcast sync next to iCloud/ABS)

    static let gpodderServerURL = "gpodderServerURL"
    static let gpodderUsername = "gpodderUsername"
    static let gpodderEnabled = "gpodderEnabled"
    /// Rolling "since" marker of the gpodder API (server returns Int timestamps).
    static let gpodderEpisodeSince = "gpodderEpisodeSince"
    /// Time (s) up to which episode actions have already been pushed.
    static let gpodderLastEpisodePush = "gpodderLastEpisodePush"
    /// Last synced subscription state (normalised feed URLs) — basis for the
    /// 3-way merge so unsubscribes are detected and propagated.
    static let gpodderLastSyncedFeeds = "gpodderLastSyncedFeeds"
    /// 2–3-feed removals held for a second consecutive-sync confirmation
    /// (normalised keys) — one per side; a diff must persist across two runs.
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

    /// F10: the user chose to run WITHOUT an ABS server (podcasts-first);
    /// every source stays individually attachable in the settings.
    static let serverlessMode = "serverlessMode"
    static var serverlessModeValue: Bool {
        get { UserDefaults.standard.bool(forKey: serverlessMode) }
        set { UserDefaults.standard.set(newValue, forKey: serverlessMode) }
    }

    // MARK: - Radio (F1)

    /// Radio source toggle — the tab appears once switched on.
    static let radioEnabled = "radioEnabled"
    static var radioEnabledValue: Bool {
        get { UserDefaults.standard.bool(forKey: radioEnabled) }
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

    // Jellyfin music server (Etappe 2) — mirrors the Subsonic key family.
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

    /// Booksonic: what this Subsonic source CONTAINS — "music" (default) or
    /// "audiobooks" (a Booksonic library maps albums to books). User-set per
    /// source, never guessed.
    static let subsonicContentType = "subsonicContentType"
    static var subsonicIsAudiobooksValue: Bool {
        get { UserDefaults.standard.string(forKey: subsonicContentType) == "audiobooks" }
        set { UserDefaults.standard.set(newValue ? "audiobooks" : "music", forKey: subsonicContentType) }
    }

    /// Drive mode: the ONE remembered car audio-route UID (user-chosen from
    /// the connected outputs; empty = no auto-activation) + its display name.
    static let driveModeCarRouteUID = "driveModeCarRouteUID"
    static let driveModeCarRouteName = "driveModeCarRouteName"
    /// 9357955: explicit auto-start opt-in (default OFF — bool(forKey:)).
    static let driveModeAutoStart = "driveModeAutoStart"

    /// f79c40c: suggestion/catalog language MULTI-selection ([String] codes);
    /// unset = device locale (SuggestionLanguages.effective).
    static let suggestionLanguages = "suggestionLanguages"

    // 0714d26: free-catalog Discover rows (each an own opt-out on the
    // network-services page; defaults ON — object(forKey:)-checked).
    static let librivoxRowsEnabled = "librivoxRowsEnabled"
    static let archivePopularEnabled = "archivePopularEnabled"
    static let jamendoRowEnabled = "jamendoRowEnabled"
    /// The user's OWN Jamendo client_id (beats the build-injected one).
    static let jamendoClientId = "jamendoClientId"
    /// f18ec34: the "Free Classical" AREA toggle (feature level, Music pill);
    /// the archive.org service opt-out stays superior.
    static let freeClassicalEnabled = "freeClassicalEnabled"
    /// 3125a42: remembered ABS import target (library picker on first use).
    static let librivoxImportLibraryId = "librivoxImportLibraryId"
    static let librivoxImportFolderId = "librivoxImportFolderId"
    /// 7edb21b: the "Free Audiobooks" AREA toggle (feature level, audiobooks
    /// pill); the LibriVox service opt-out stays superior.
    /// e4bd910: the radio-logo fallback chain (Wikidata P154 → homepage
    /// touch icon) behind the gated favicon — network-services opt-out.
    static let radioLogoChainEnabled = "radioLogoChainEnabled"
    nonisolated static var radioLogoChainEnabledValue: Bool {
        UserDefaults.standard.object(forKey: radioLogoChainEnabled) as? Bool ?? true
    }
    /// 593d177 R2: normalized feed URLs the USER unsubscribed — only these
    /// may propagate to the gpodder server without the two-sync confirmation.
    static let gpodderUserRemovedFeeds = "gpodderUserRemovedFeeds"
    /// 92e25d6: feed keys the user MARKED as premium manually (the escape
    /// hatch for unknown URL patterns) — feeds the ONE premium truth.
    static let premiumMarkedFeeds = "premiumMarkedFeeds"
    /// 5034add: MASTER switch over every free-catalog surface + its traffic.
    static let freeCatalogsMasterEnabled = "freeCatalogsMasterEnabled"
    static let freeAudiobooksEnabled = "freeAudiobooksEnabled"

    // Radio-Picker-Kuratierung (b942da6/b1ab99d)
    /// ALL raw name variants of the chosen region (the by-state query runs
    /// against every one; [String] via UserDefaults array).
    static let radioRegionQueryNames = "radioRegionQueryNames"
    /// Country implied by the chosen region (cascade step b).
    static let radioRegionCountryCode = "radioRegionCountryCode"
    static let radioRegionCountryName = "radioRegionCountryName"
    /// Explicitly chosen country (cascade step a — beats every guess).
    static let radioChosenCountryCode = "radioChosenCountryCode"
    static let radioChosenCountryName = "radioChosenCountryName"

    /// Artist portraits from open sources (MB→Wikidata→Commons; opt-out —
    /// server images always win, off just means color circles).
    static let musicArtistImagesOnline = "musicArtistImagesOnline"
    static var musicArtistImagesOnlineValue: Bool {
        get { UserDefaults.standard.object(forKey: musicArtistImagesOnline) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicArtistImagesOnline) }
    }

    /// Radio: the ONE user-chosen state for the region section (nil = not
    /// chosen; chosen once, persisted — no location permission, ever).
    static let radioRegionState = "radioRegionState"

    /// Listen log: one-time backfill of the current subscriptions done.
    static let listenLogBackfilled = "listenLogBackfilled"

    /// gpodder: the deviceId this install has REGISTERED on the server
    /// (one-shot per id; the id itself is never re-rolled for existing users).
    static let gpodderDeviceRegisteredFor = "gpodderDeviceRegisteredFor"

    /// M5: LRCLIB lyrics lookup (opt-out; server lyrics always win).
    static let musicLyricsOnlineLookup = "musicLyricsOnlineLookup"
    static var musicLyricsOnlineLookupValue: Bool {
        get { UserDefaults.standard.object(forKey: musicLyricsOnlineLookup) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: musicLyricsOnlineLookup) }
    }

    /// M6: high-res covers from the Cover Art Archive (opt-out).
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
    /// so the rule lives in one place (Regel 2, `PodcastServerExclusivity`).
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

    // MARK: - Library toggles (TF bib-toggles): two levels — tab master + source

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

    /// Per-source toggles that were missing (ABS-audiobooks, RSS). Default ON —
    /// they only surface content when there IS content anyway (token / feeds).
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
    static var subsonicActive: Bool {
        // Booksonic: the source gates on the tab it actually serves.
        SourceActivation.effective(
            tabEnabled: subsonicIsAudiobooksValue ? audiobooksTabEnabledValue : musicTabEnabledValue,
            sourceEnabled: subsonicEnabledValue)
    }
    static var jellyfinActive: Bool {
        SourceActivation.effective(tabEnabled: musicTabEnabledValue, sourceEnabled: jellyfinEnabledValue)
    }
    static var radioActive: Bool {
        SourceActivation.effective(tabEnabled: radioTabEnabledValue, sourceEnabled: radioEnabledValue)
    }

    /// Notify about new podcast episodes (background refresh). Opt-in.
    static let podcastNewEpisodeNotifications = "podcastNewEpisodeNotifications"
    static var podcastNewEpisodeNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: podcastNewEpisodeNotifications)
    }

    /// Sync podcast progress across your own devices via iCloud.
    static let podcastICloudSync = "podcastICloudSync"
    static var podcastICloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: podcastICloudSync) as? Bool ?? true
    }
    static let lastPlayedItemId = "lastPlayedItemId"
    static let pendingDownloadDestinations = "pendingDownloadDestinations"
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
    /// FULL library list (never the filtered offline list — valid keys would be
    /// dropped otherwise).
    static func cleanupPerBookKeys(validItemIds: Set<String>) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["playbackRate.", "localPosition."] where key.hasPrefix(prefix) {
                let id = String(key.dropFirst(prefix.count))
                // Only prune raw ABS book ids. Podcast/local keys
                // (`rss:`/`abspod:`/`local:`) belong to other sources with their
                // own lifecycle — `validItemIds` holds audiobooks only, so all
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
