# Mär

A lightweight, open-source iOS/iPadOS client for [Audiobookshelf](https://www.audiobookshelf.org/).
The app focuses on one thing: **reliable playback progress sync** across multiple devices, without accidentally resetting a book to 0 — including while fully offline.

> „Mär“ is an old German word for a tale or story — fitting for an audiobook player. The Xcode project is still called `ABSPlayer` internally; “Mär” is only the display name.

Mär started as a private replacement for a client that regularly lost playback progress when switching devices. The app is intentionally minimal: no multi-user support, no podcasts, no server administration — just listening to audiobooks and keeping progress in sync, online or off.

> **Note:** This is a private hobby project without warranty. It is not affiliated with the Audiobookshelf project.

## Screenshots

| Library | Player | Book page |
|---|---|---|
| ![Library](screenshots/iphone_library.png) | ![Player](screenshots/iphone_player.png) | ![Book page](screenshots/iphone_detail.png) |

| Library (iPad) | Book page (iPad) |
|---|---|
| ![Library on iPad](screenshots/ipad_library.png) | ![Book page on iPad](screenshots/ipad_detail.png) |

| Library (landscape) | Book page (landscape) |
|---|---|
| ![Library in landscape](screenshots/iphone_library_landscape.png) | ![Book page in landscape](screenshots/iphone_detail_landscape.png) |

## Features

- Sign in with username/password or an API token, compatible with both the old and new Audiobookshelf authentication systems
- Library as an adaptive cover grid for iPhone and iPad, self-sizing to always fit the actual screen width without overlap, even across rotation
- **Search overlay**: a floating glass search button opens a full glass sheet above the library (the library shimmers through, slightly dimmed) with an auto-focused field, real-time filtering per keystroke, and scope chips — All / Author / Genre / Series; results are rows with small cover thumbnails, group scopes drill down in place, and picking a book closes the overlay and pushes its detail page
- Sorting by title, author, recently added, or recently listened, with an ascending/descending toggle; sort and filter choices are remembered across app launches
- Filters for all/unfinished/finished books
- “Continue Listening”, “Recently Added”, and “Downloaded” sections
- Haptic Touch context menu on covers for quick actions: play, download, mark as heard
- Progress bar, “Finished” checkmark, and download-status badge directly on each cover; finished books are shown slightly desaturated
- Book detail page with description, narrator, series, genres, publication year, and total duration; download and “Mark as heard” directly from the detail page, with a play/pause button that correctly reflects and controls an already-playing session
- Persistent floating mini-player styled after Apple's Liquid Glass design (iOS 26, with a safe fallback material on older versions), with a circular progress ring around the cover; extra transport controls (skip forward/back, AirPlay) appear only on iPad or in landscape, keeping more room for the title on iPhone portrait; automatically restores the last listening session after a full app restart, paused and never auto-playing
- Full player as a rounded Liquid Glass sheet floating above the library — drag it down (grab handle or side zones) to dismiss back to the mini-player, with the library showing through the glass during the pull; large cover, cover-derived gradient background, chapter markers directly on the scrubber, play/pause/scrub, configurable skip interval (15/30/60 s, also applied to lock screen and mini-player buttons), playback speed remembered per book, sleep timer with fixed minutes or until chapter end, AirPlay, “Mark as listened”, and subtle haptic feedback; in landscape (iPhone and iPad) the cover moves next to the controls
- Transient glass pill for sync/source events (“resumed from server”, “offline — queued”, “progress saved”, “conflict detected”) shown above the mini-player or in the full player, auto-hiding after a few seconds
- Background audio, lock screen and Dynamic Island display including cover artwork
- **Multi-track playback**: audiobooks split across several audio files (not converted to a single M4B) play back-to-back seamlessly, with correct chapter and progress handling across the whole book
- **Offline download** per book, manually triggered with a Wi-Fi warning; downloads every track of a book, not just the first, continues while the app is in the background, shows a live progress ring on the cover badge, and caches its chapters/metadata locally — a downloaded book opens and plays fully offline, without needing to reach the server just to show its chapter list
- **Offline library**: when the server is unreachable, the library shows the downloaded (actually playable) books from the disk cache — covers of downloaded books are stored persistently, so they survive iOS cache purges; covers are cached at device-appropriate resolution without recompression
- **Offline sync queue**: a progress update that fails to send — whether offline or due to a server error — is queued on disk (atomically) and automatically retried on the next app start or as soon as the connection returns; before flushing, the queue reconciles against the server so a stale queued position never overwrites a newer one from another device
- Automatic reconnect detection: the library and any queued sync updates refresh by themselves once the connection comes back, without needing to background/foreground the app
- **Safe progress sync**; see below
- Multi-device progress reconciliation
- **Bookmarks** per book (position + title) synced through the Audiobookshelf bookmark API, created from the player, with offline queueing — bookmarks created or deleted without a connection are sent automatically once it returns
- Settings screen: skip interval, default playback speed for new books, **Smart Rewind** (resume a little earlier after longer pauses), **auto-play the next unfinished book of a series**, appearance override (system/light/dark), Wi-Fi download warning toggle, storage management, sync status with a “Sync Now” button, a library picker for servers with several libraries, and the app version
- **Siri & Shortcuts**: “Continue listening in Mär” and “Play *book* in Mär” (book names come from the offline library cache), plus a home-screen quick action that resumes the last played book
- **Live Activity / Dynamic Island** for the sleep timer: while a timer runs, a moon countdown shows on the lock screen and in the Dynamic Island (frozen while paused in end-of-chapter mode) — deliberately nothing more, since Apple's own Now Playing already covers playback on the lock screen; requires adding the widget extension target once, see `LiveActivityWidget/ANLEITUNG.md`
- **CarPlay**: three tabs (Continue Listening / Downloaded / Library) with cover thumbnails and the system Now Playing screen, sharing the phone's playback session — works on a cold start in the car, falling back to the offline cache; testable in the simulator out of the box, real cars need Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay)
- Adaptive light and dark design: the Liquid Glass chrome (mini player, search, toolbar buttons) takes a soft pastel wash of the current cover color in light mode, and the mini player dips off-screen and springs back when switching books
- Performance: grid cells decode a small derived thumbnail instead of the full cover — smooth scrolling and far less memory with large libraries; the book list is fetched in Audiobookshelf’s minified format
- Hardening: free-space check before downloads start, magic-byte container detection with automatic file-extension repair (unit-tested), automatic recovery when a track fails mid-playback instead of silent stalling, VoiceOver labels on all transport controls

## Core sync rule

This is the heart of the app. A user-triggered seek action — scrubber, chapter jump, ±30s, or lock screen control — is treated as intentional and synced immediately, even backwards. A warning dialog only appears if progress drops by more than 120 seconds **without user action**, for example due to a faulty client reset. If the user cancels, playback jumps back to the last stored position.

When switching devices, the app briefly checks the server before each playback start. The entry with the newer timestamp wins: if another device wrote last, its position is adopted — even if it is **further back** (e.g. after deliberately rewinding there). On older servers without a timestamp, only a further-ahead server position is adopted. True simultaneous listening on two devices is not covered; in that case, the last writer wins.

Every progress write always sends a complete record (current time, duration, and finished status together) rather than a partial update — a partial update leaves the server to guess what to do with the fields it wasn't given, which previously caused real progress loss when only the finished flag was toggled.

## Intentionally not included

Multi-user support, podcasts, metadata editing, and server/library administration.

## Requirements

- Xcode with an iOS 26 SDK available (needed to build at all, since the mini-player and search button use Apple's Liquid Glass API behind an availability check) with Swift 5.9+
- Deployment target iOS/iPadOS 17+ — the app still runs on older iOS versions at runtime, falling back to a plain translucent material instead of Liquid Glass
- A running Audiobookshelf server and either your account credentials or an API token
- An Apple ID for signing; a free Apple ID is sufficient, see the note on 7-day signing below

## License

MIT — see [LICENSE](LICENSE).

---

## 1. Sign-in options

The app signs in either with your Audiobookshelf **username and password** (the default — it exchanges them for a token via `/login` and stores only the token in the keychain) or directly with an **API token**.

Note for servers on the new JWT authentication (v2.26.0+): the password login receives a short-lived access token there, so the session can expire and return you to the setup screen. On such servers an API key is the more durable choice.

How to find your token:

- **Older server versions:** Web interface → Settings → Users → select your account → the token is displayed.
- **Newer server versions:** Web interface → Settings → API Keys → create a new key.

If you are not sure which variant your server uses, try both. One of these paths will exist.

---

## 2. Build & install

The repository ships the complete Xcode project — nothing needs to be assembled:

1. Clone the repo and open **`Maer.xcodeproj`** (Xcode with an iOS 26 SDK).
2. **Signing** (target `ABSPlayer` → Signing & Capabilities):
   - **Team:** your Apple ID — a free one is enough (see note below)
   - **Bundle Identifier:** change it to something unique, e.g. `de.yourname.maer`, on BOTH targets (`ABSPlayer` and `MaerWidgetsExtension` — the widget ID must stay a child of the app ID, e.g. `de.yourname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift`, set the `service` constant to the same bundle identifier.
3. Connect your iPhone, select it as the run destination (background audio is far more reliable to test on a real device than in the simulator), press ▶.
4. On the iPhone, trust your Apple ID once under **Settings → General → VPN & Device Management** if asked.

Background audio, the Live-Activity widget target, the CarPlay scene, and iPhone/iPad support are already configured in the project.

**Free Apple ID without the Developer Program:** the app runs for 7 days per install, then rebuild once via Xcode. **CarPlay in a real car** additionally needs Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay, paid account) — the CarPlay simulator (`I/O → External Displays → CarPlay`) works without it.

## 3. Log in inside the app

- Server: `your-server.example.com`; `https://` is added automatically
- Then either username + password, or an API token from step 1

---

## iPad support

iPhone and iPad are both enabled in the project. The library grid adapts automatically to the available width — more columns on iPad, even more in landscape — and recalculates cleanly on every rotation. On iPhone portrait, the mini-player hides its secondary transport buttons (skip forward/back, AirPlay) to leave more room for the book title; they reappear automatically on iPad or in iPhone landscape.

```text
Sources/
├── ABSPlayerApp.swift              Entry point + AppDelegate for background download events
├── AppSession.swift                Process-wide session (player/library shared with CarPlay)
├── AppShortcuts.swift              Siri App Intents (continue listening, play a specific book)
├── Providers/
│   ├── AudioProvider.swift         Protocol every audio source implements (login, library,
│   │                               search, stream, download, sync) — the core sees only this
│   ├── ABSProvider.swift           Audiobookshelf as the first provider
│   ├── LocalProvider.swift         Imported local audio files (no server)
│   ├── LocalLibrary.swift          Local file index + AVAsset metadata extraction
│   ├── RSSProvider.swift           Podcasts: RSS episodes mapped to library items
│   └── PodcastSubscriptions.swift  Feed store + XMLParser-based RSS/Atom parser
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay tabs (continue/downloaded/library) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable structs for the Audiobookshelf API
│   ├── SyncRules.swift             Pure, unit-tested sync decision rules + multi-track time math
│   ├── PlaybackActivityAttributes.swift  Shared Live-Activity contract (app + widget extension)
│   └── AppStorageKeys.swift        Central UserDefaults keys incl. per-book key cleanup
├── Networking/
│   ├── APIClient.swift             All HTTP calls
│   ├── KeychainStore.swift         Secure storage for server URL and token
│   ├── DownloadManager.swift       Multi-track offline downloads and their cached metadata
│   ├── FileDownloader.swift        Shared background URLSession download with progress reporting
│   ├── ImageCache.swift            Cover cache: memory + purgeable disk + persistent store for downloaded books
│   ├── NetworkMonitor.swift        Continuous connectivity observation (auto-reconnect)
│   ├── NetworkStatus.swift         One-shot Wi-Fi check and shared offline-error detection
│   ├── BookmarkQueue.swift         Offline queue + cache for bookmark create/delete
│   └── SyncQueue.swift             Persistent queue for failed progress updates (storage/API
│                                   behind protocols for testability)
├── ViewModels/
│   ├── AuthViewModel.swift         Setup screen logic
│   ├── LibraryViewModel.swift      Loads book list and progress, sorting, series grouping,
│   │                               offline disk cache
│   ├── PlayerCoordinator.swift     Keeps the active session alive across navigation,
│   │                               offline-aware, basis for the mini-player
│   ├── PlayerViewModel.swift       AVQueuePlayer, multi-track queue, seek/skip, chapters
│   ├── PlayerViewModel+Sync.swift  Sync policy: timer, reentrancy guard, conflicts, reconcile
│   ├── PlayerViewModel+SleepTimer.swift   Sleep timer incl. volume fade
│   ├── PlayerViewModel+LiveActivity.swift Live Activity start/update/end
│   └── PlayerViewModel+NowPlaying.swift   Lock screen commands, NowPlaying info, artwork
└── Views/
    ├── SetupView.swift             Server + password or token sign-in
    ├── SettingsView.swift          Playback, appearance, storage, sync, server settings
    ├── RootView.swift              Switches between setup and library
    ├── LibraryView.swift           Book list, sort/filter, sections, adaptive grid
    ├── SearchOverlay.swift         Full glass search sheet (real-time, scopes, drill-down)
    ├── FullPlayerOverlay.swift     Draggable Liquid Glass sheet hosting the full player
    ├── SeriesStackCell.swift       Series stack tile (fanned covers + count badge)
    ├── BookDetailScreen.swift      Book detail page, download, mark as heard, play/pause
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
    └── Haptics.swift               Small haptic feedback helper
```

**Mini-player architecture note:** `PlayerCoordinator` lives in `LibraryView` and survives navigation. Playback is not stopped when leaving the player screen or when the mini-player is temporarily hidden — it only stops when explicitly opening a different book.

API endpoints used:

| Purpose | Endpoint |
|---|---|
| Libraries | `GET /api/libraries` |
| Book list | `GET /api/libraries/{id}/items?minified=1` |
| Book details, chapters and progress | `GET /api/items/{id}?expanded=1` |
| Write progress | `PATCH /api/me/progress/{itemId}` |
| Progress for the whole library | `GET /api/me` |
| Password sign-in | `POST /login` |
| Bookmarks | `GET /api/me`, `POST/DELETE /api/me/item/{id}/bookmark…` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio stream | direct `contentUrl` from the track data, with `Authorization: Bearer` header |

## About this project

Mär was created with support from AI.
