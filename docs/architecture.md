# Mär: source layout

Back to the [README](../README.md) · [Deutsch](architecture.de.md)

## Source layout

The tree below is a selection, not the whole repository (`Sources/` holds several hundred files; `tools/` is not part of the Xcode project, and the sync service has its own repository). It names the layers that carry the app today; every line describes the file it names.

```text
Sources/
├── MaerApp.swift                   Entry point + AppDelegate for background download events;
│                                   waits for every row chain and checkpoints the database
│                                   on background and termination
├── AppSession.swift                Process-wide session (player coordinator, library, providers;
│                                   shared with CarPlay)
├── AppShortcuts.swift              Siri App Intents (continue listening, play a book, a routine,
│                                   the iOS 27 audio domain and Spotlight; books from the library rows)
├── Storage/                        The one database file (maer.sqlite) and every row store
│   ├── MaerDatabase.swift          The one file and the one connection; checkpoint on the way out
│   ├── SQLiteConnection.swift      Actor over the system SQLite3, one statement at a time, WAL
│   ├── SQLiteStatements.swift      The statement mechanics both connections share
│   ├── SQLiteReader.swift          Read-only reader for the synchronous start of a store
│   ├── KeyedRowStore.swift         A dictionary as rows (key + JSON payload), diff writes
│   ├── RowChain.swift              The one write chain of a row store, awaited before the checkpoint
│   ├── RowKeeper.swift             Start read of a store's rows and its serial write chain
│   ├── RowBase.swift               Pure: what a store knows about its rows before a write
│   ├── OwnerMark.swift             Which account a family's rows belong to, written with them
│   ├── RestingShelf.swift          Where a family's rows rest while another account owns the device
│   ├── ShelfFollower.swift         The one way a family follows the account through the shelf
│   ├── CarrierRows.swift           What the carriers keep between rounds as rows (mirrors, queues,
│   │                               choice stamps, documents), the jump rings and offline bookmarks per book
│   ├── PodcastRowStore.swift       Shows and episodes as rows
│   ├── LibraryRowStore.swift       Library items and progress as rows
│   └── StandStore.swift, StandMirror.swift   Listening positions as rows, mirrored from the defaults
├── Providers/
│   ├── AudioProvider.swift         Protocol every audio source implements (login, library,
│   │                               search, stream, download, sync); the core sees only this
│   ├── ABSProvider.swift           Audiobookshelf as the first provider
│   ├── LocalProvider.swift         Imported local audio files (no server)
│   ├── LocalLibrary.swift          Local file index (rows) + AVAsset metadata extraction
│   ├── SubsonicProvider.swift      Subsonic/OpenSubsonic music (Navidrome, gonic, Airsonic)
│   ├── JellyfinProvider.swift      Jellyfin music and audiobooks (jf: namespace; a folder folds to one book)
│   ├── FreeCatalogProvider.swift   Playback for the open catalogs (LibriVox, archive.org, Jamendo)
│   ├── RadioProvider.swift         Internet radio (radio: namespace), Radio Browser + own URLs
│   ├── RSSProvider.swift           Podcasts: RSS episodes mapped to library items
│   ├── MaerPlaylists.swift         Mär playlists (rows): the SECOND playlist type, mixing every id
│   ├── ABSPodcastProvider.swift    Audiobookshelf podcast libraries (opt-in source)
│   ├── PodcastSubscriptions.swift  Feed store (rows) + XMLParser-based RSS/Podcasting-2.0 parser
│   ├── PodcastSubscriptionSync.swift  Reconciled local ↔ ABS subscription mirroring
│   ├── PodcastDirectory.swift      Discovery via PodcastIndex + iTunes charts
│   ├── PodcastRecommendationsStore.swift  Usage-driven, themed recommendation ranking
│   ├── ProviderSearch.swift        SearchableProvider capability + per-source search
│   ├── PlayQueue.swift             Global cross-media up-next queue (one row)
│   ├── UpNextArrivals.swift        New episodes of a show into Up Next after a refresh
│   ├── PlaybackContext.swift       The rest of a collection start (one row), not the queue
│   └── PodcastImport.swift         Apple Podcasts, Overcast, AntennaPod and OPML import
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay tabs (Home + audiobooks + podcasts + music + radio) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable structs for the Audiobookshelf API
│   ├── SubsonicModels.swift        Codable structs for the Subsonic/OpenSubsonic API
│   ├── JellyfinModels.swift, JellyfinBookFold.swift   Jellyfin structs; pure folding of a folder into one book
│   ├── RadioModels.swift           Foundation-only radio core (mapping, ICY parse, store)
│   ├── FreeCatalog*.swift          The open catalogs: sources, decoders, rights labels
│   ├── MediaType.swift             The four media types (audiobooks/podcasts/music/radio)
│   ├── SyncRules.swift             Pure, unit-tested sync decision rules + multi-track time math
│   ├── SyncHistory.swift           Pure sync-history entries + ring buffer
│   ├── UserChoiceSync.swift        The catalog of every stored choice and its sync class
│   ├── HomeSections.swift          Home aggregation (recency, fair interleave)
│   ├── RediscoverSections.swift    Rediscover picks (paused / unheard / next in series)
│   ├── SearchModels.swift          Search result/ranking types
│   ├── AppStorageKeys.swift        Central UserDefaults keys, one activation answer per source
│   ├── SourceMap.swift             Pure: the five areas and what each needs (map states)
│   ├── MaerPlaylistMerge.swift     Pure: per-list merge, rescued version, tombstones
│   ├── UpNextAuto.swift            Pure: which new episodes go into Up Next, and where
│   ├── ServerHeaderRule.swift      Pure: which request carries a server's own headers, and where a redirect leaves them
│   ├── HeardElsewhere.swift        Pure: a mark from elsewhere that made a title played
│   ├── SharedLink.swift            Pure: the maer.fm link, what it names and what may be shared
│   ├── ABSSingleSignOn.swift, ABSSignInMethods.swift   Pure: the Audiobookshelf single sign-on
│   │                               (start, return, exchange) and the ways a server offers
│   └── PodcastAutoDownloadRules.swift  Pure: what the automatic download may clean up
├── Networking/
│   ├── APIClient.swift             Audiobookshelf HTTP calls
│   ├── ABSSSOFlow.swift            The single sign-on in the system's sign-in window
│   ├── AppUserAgent.swift          THE one identity the app shows foreign servers
│   ├── StandCarrier.swift, ClaimCarrier.swift, StatsCarrier.swift,
│   │   PlaylistCarrier.swift, ChoiceCarrier.swift
│   │                               The carrier seams: each with a key-value, a CloudKit and a
│   │                               sync-service carrier behind it; the runners know none of them
│   ├── CloudZoneDatabase.swift, CloudStandDatabase.swift, CloudKit*Carrier.swift
│   │                               iCloud's private database: one zone per record type
│   ├── MaerSyncClient.swift, MaerSyncCarriers.swift, MaerSyncSignIn.swift
│   │                               The Mär sync service: address and token, one session for
│   │                               six document kinds, the sign-in that sends a proof, never the password
│   ├── PodcastCloudSync.swift      Runner of the listening positions across your devices (via a carrier)
│   ├── PlaybackClaimSync.swift     Runner of the "playing on another device" claim (via a carrier)
│   ├── UserChoiceCloudSync.swift   Runner of the travelling choices (via a carrier)
│   ├── MaerPlaylistCloudSync.swift Runner of the Mär playlists across your devices (via a carrier)
│   ├── KeychainStore.swift         Secure storage for server URLs and tokens
│   ├── DownloadManager.swift       Multi-track offline downloads; the download marks are rows
│   ├── FileDownloader.swift        Shared background URLSession download with progress reporting
│   ├── ImageCache.swift, Artwork.swift   Cover cache and THE one door every cover passes
│   ├── SubsonicClient.swift        Subsonic/OpenSubsonic API (token+salt auth, streaming, lyrics)
│   ├── JellyfinClient.swift        Jellyfin API (Authorization header, ApiKey on media links)
│   ├── PinchflatClient.swift       Pinchflat: the channel list as an OPML mirror, feeds ride RSS
│   ├── ServerHeaders.swift         A server's own headers in the iCloud keychain, set at the four ways out
│   ├── SignInStream.swift          A stream with a sign-in is asked at the end of its redirects
│   ├── CoverArtArchive.swift       High-res album covers via MusicBrainz ID (rate-limited)
│   ├── RadioBrowserClient.swift    Radio Browser catalog client (mirror fallback)
│   ├── SyncHistoryStore.swift      Sync history (rows) + per-service "last checked"
│   ├── NetworkMonitor.swift        Continuous connectivity observation (auto-reconnect)
│   ├── NetworkStatus.swift         One-shot Wi-Fi check and shared offline-error detection
│   ├── BookmarkQueue.swift         Offline queue + cache for bookmark create/delete
│   ├── SyncQueue.swift             Queue for failed progress updates (rows, landed before the
│   │                               call returns; storage and API behind protocols for tests)
│   ├── Retry.swift                 Backoff retry for transient network errors
│   ├── URLSession+Maer.swift       Shared session with sane request/resource timeouts
│   ├── GPodderClient.swift         gpodder/mygpo API client (login, devices, subscriptions, episodes)
│   ├── GPodderSync.swift           3-way reconcile of gpodder subscriptions + play actions
│   ├── PodcastFeedAuth.swift       Per-feed HTTP Basic auth for premium feeds (keychain)
│   ├── PodcastRefreshService.swift Background feed refresh + new-episode notifications
│   └── PodcastServerSave.swift     Deferred server-side save of streamed feed episodes
├── ViewModels/
│   ├── AuthViewModel.swift         Setup screen logic
│   ├── SharedLinkOpener.swift      What a maer.fm link opens in the app (a page, never playback)
│   ├── GlobalSearchModel.swift, SearchDoor.swift   Cross-source search and its one door
│   ├── LibraryViewModel.swift      Loads book list and progress, sorting, series grouping,
│   │                               offline cache as rows
│   ├── PlayerCoordinator.swift     Keeps the active session alive across navigation,
│   │                               offline-aware, basis for the mini-player
│   ├── StreamPlanner.swift         Where streams with server headers or a sign-in end: the first
│   │                               track before the start, then the playing track and the next two
│   ├── PlayerViewModel.swift       AVQueuePlayer, multi-track queue, seek/skip, chapters
│   ├── PlayerViewModel+Sync.swift  Sync policy: timer, reentrancy guard, conflicts, reconcile
│   ├── PlayerViewModel+SleepTimer.swift   Sleep timer incl. volume fade
│   ├── PlayerViewModel+NowPlaying.swift   Lock screen commands, NowPlaying info, artwork
│   └── AppHousekeeping.swift       The start-up and re-activation chores, in one order
└── Views/
    ├── SetupView.swift             First screen: the map of areas + start without a
    │                               server; holds ABSLoginForm/ABSLoginPage (the ONE
    │                               Audiobookshelf sign-in, also used behind "Connect")
    ├── SourceMapCard.swift         THE map of areas: first screen AND the sources
    │                               overview in the settings, plus SourceAreaPage
    ├── SettingsView.swift          Playback, appearance, storage, sync, server settings
    ├── MaerSyncSettingsView.swift  Settings, Sync: the Mär sync service (sign in, test, refusals)
    ├── SourcesSettingsView.swift, RowsSettingsView.swift   Which sources and rows the tabs show
    ├── StatsView.swift             Listening statistics
    ├── RootView.swift              Switches between setup and library
    ├── LibraryView.swift           Book list, sort/filter, sections, adaptive grid
    ├── HomeView.swift              Cross-media start tab (continue/rediscover/discover/latest)
    ├── SearchScreen.swift          Full-page global search (scope bar, browse deck, catalog)
    ├── FullPlayerOverlay.swift     Draggable Liquid Glass sheet hosting the full player
    ├── DriveMode.swift, DriveModeView.swift   Drive mode: big-button player, automatic entry
    ├── SeriesStackCell.swift       Series stack tile (fanned covers + count badge)
    ├── BookDetailScreen.swift      Book detail page, download, mark as finished, play/pause
    ├── BookCoverView.swift         Cover with progress bar and status badges, reused across views
    ├── BookGridComponents.swift    Shared grid cell + context menu, author/genre browse screens
    ├── BookmarksSheet.swift        Bookmark list/create/delete sheet in the player
    ├── CachedAsyncImage.swift      AsyncImage replacement backed by ImageCache
    ├── MiniPlayerBar.swift         Persistent floating glass mini-player
    ├── FloatingSearchButton.swift  Floating glass button that opens the search overlay
    ├── AdaptiveGlassBackground.swift  Shared Liquid Glass styling with material fallback
    ├── AirPlayButton.swift         AirPlay route picker wrapper
    ├── PlayerScreen.swift          Full player, displays the coordinator session
    ├── PlayerView.swift            Audible-style player UI
    ├── CoverColorLoader.swift      Extracts an accent color from the cover
    ├── ChapterListView.swift       Chapter list as a sheet
    ├── Haptics.swift               Small haptic feedback helper
    ├── MediaTabBar.swift           Home/Audiobooks/Podcasts/Music/Radio media-type switcher
    ├── MediaTile.swift             Shared grid tile (home, latest episodes, recommendations)
    ├── MediaRowContent.swift       Shared list-row layout (podcast episodes, books, stations)
    ├── SyncHistoryView.swift       Settings: sync history ("last checked" + change ring)
    ├── ABSSourceView.swift         Audiobookshelf source page (access, sync)
    ├── SubsonicSourceView.swift    Music source page (server, credentials, sync)
    ├── JellyfinSourceView.swift    Jellyfin source page
    ├── RadioSourceView.swift       Radio source page (enable, own stream URLs)
    ├── FreeAudiobooksPage.swift, CatalogSourcePage.swift   The open catalogs' pages
    ├── SharedLinkButton.swift      The share button and the share sheet's preview with the cover
    ├── PodcastsView.swift          Podcast home (continue, recommendations, queue, shelves)
    ├── PodcastSourceView.swift     Add/import podcasts and pick subscription sources
    ├── Podcasts/                   Show, episode, queue, discover, per-show settings, cards
    ├── Music/                      Music home, album, artists, playlists, lyrics panel
    └── Radio/                      Radio tab, station rows, shared radio artwork
```

**Mini-player architecture note:** `PlayerCoordinator` lives in `AppSession` (process-wide, shared with CarPlay) and survives navigation. Playback is not stopped when leaving the player screen or when the mini-player is temporarily hidden; it only stops when explicitly opening a different book.
