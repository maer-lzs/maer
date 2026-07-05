# Hörregal

A lightweight, open-source iOS/iPadOS client for [Audiobookshelf](https://www.audiobookshelf.org/).
The app focuses on one thing: **reliable playback progress sync** across multiple devices, without accidentally resetting a book to 0 — including while fully offline.

> The name refers to the “shelf” in Audiobookshelf — Hörregal is your audiobook shelf for iPhone and iPad. The Xcode project is still called `ABSPlayer` internally; “Hörregal” is only the display name.

Hörregal started as a private replacement for a client that regularly lost playback progress when switching devices. The app is intentionally minimal: no multi-user support, no podcasts, no server administration — just listening to audiobooks and keeping progress in sync, online or off.

> **Note:** This is a private hobby project without warranty. It is not affiliated with the Audiobookshelf project.

## Screenshots

| Bibliothek | Detail Book (iPhone) | Player (iPad) |
|---|---|---|
| ![Bibliothek](screenshots/iphone_bib.png) | ![Detail](screenshots/iphone_detail.png) | ![Player iPad](screenshots/ipad_player.png) |

## Features

- Login via API token, compatible with both the old and new Audiobookshelf authentication systems
- Library as an adaptive cover grid for iPhone and iPad, self-sizing to always fit the actual screen width without overlap, even across rotation
- Floating search button (Music-app style) that expands into a search field instead of a fixed search bar
- Sorting by title, author, recently added, or recently listened, with an ascending/descending toggle; sort and filter choices are remembered across app launches
- Filters for all/unfinished/finished books
- “Continue Listening”, “Recently Added”, and “Downloaded” sections
- Haptic Touch context menu on covers for quick actions: play, download, mark as heard
- Progress bar, “Finished” checkmark, and download-status badge directly on each cover; finished books are shown slightly desaturated
- Book detail page with description, narrator, series, genres, publication year, and total duration; download and “Mark as heard” directly from the detail page, with a play/pause button that correctly reflects and controls an already-playing session
- Persistent floating mini-player styled after Apple's Liquid Glass design (iOS 26, with a safe fallback material on older versions), with a circular progress ring around the cover; extra transport controls (skip forward/back, AirPlay) appear only on iPad or in landscape, keeping more room for the title on iPhone portrait; automatically restores the last listening session after a full app restart, paused and never auto-playing
- Full player: large cover, cover-derived gradient background, chapter markers directly on the scrubber, play/pause/scrub/±30s, playback speed, sleep timer with fixed minutes or until chapter end, AirPlay, “Mark as listened”, and subtle haptic feedback
- Background audio, lock screen and Dynamic Island display including cover artwork
- **Multi-track playback**: audiobooks split across several audio files (not converted to a single M4B) play back-to-back seamlessly, with correct chapter and progress handling across the whole book
- **Offline download** per book, manually triggered with a Wi-Fi warning; downloads every track of a book, not just the first, and caches its chapters/metadata locally — a downloaded book opens and plays fully offline, without needing to reach the server just to show its chapter list
- **Offline library**: the book list and its cover images are cached to disk, so the library (including everything already downloaded) stays browsable even after a full app restart with no connection at all
- **Offline sync queue**: a progress update that fails to send while offline is queued on disk and automatically retried on the next app start or as soon as the connection returns — even a hard app kill while offline won't lose it
- Automatic reconnect detection: the library and any queued sync updates refresh by themselves once the connection comes back, without needing to background/foreground the app
- **Safe progress sync**; see below
- Multi-device progress reconciliation

## Core sync rule

This is the heart of the app. A user-triggered seek action — scrubber, chapter jump, ±30s, or lock screen control — is treated as intentional and synced immediately, even backwards. A warning dialog only appears if progress drops by more than 120 seconds **without user action**, for example due to a faulty client reset. If the user cancels, playback jumps back to the last stored position.

When switching devices, the app briefly checks the server before each playback start. If another device has the newer position, that server position is adopted instead of overwritten. True simultaneous listening on two devices is not covered; in that case, the last writer wins.

Every progress write always sends a complete record (current time, duration, and finished status together) rather than a partial update — a partial update leaves the server to guess what to do with the fields it wasn't given, which previously caused real progress loss when only the finished flag was toggled.

## Intentionally not included

Multi-user support, podcasts, metadata editing, and server/library administration.

## Requirements

- Xcode with an iOS 26 SDK available (needed to build at all, since the mini-player and search button use Apple's Liquid Glass API behind an availability check) with Swift 5.9+
- Deployment target iOS/iPadOS 17+ — the app still runs on older iOS versions at runtime, falling back to a plain translucent material instead of Liquid Glass
- A running Audiobookshelf server and an API token
- An Apple ID for signing; a free Apple ID is sufficient, see the note on 7-day signing below

## License

MIT — see [LICENSE](LICENSE).

---

## 1. Why no username/password login?

Newer Audiobookshelf versions, starting with v2.26.0, switched the authentication system to JWT with access and refresh tokens. For a minimal app, that would add unnecessary complexity such as cookie handling and token refresh logic.

How to find your token:

- **Older server versions:** Web interface → Settings → Users → select your account → the token is displayed.
- **Newer server versions:** Web interface → Settings → API Keys → create a new key.

If you are not sure which variant your server uses, try both. One of these paths will exist.

---

## 2. Create the Xcode project

1. Open Xcode → **File → New → Project**
2. Select **iOS → App**
3. Use these settings:
   - Product Name: `ABSPlayer`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None**; no Core Data
   - Tests: can be unchecked; they are not needed here
4. Save the project locally
5. Select the project file → Target `ABSPlayer` → **General** tab → set **Minimum Deployments** to **iOS 17.0**

## 3. Add the files

1. In the Xcode project navigator, delete the automatically generated `ContentView.swift` file by choosing Move to Trash. Also delete the automatically generated `ABSPlayerApp.swift`.
2. Drag the complete `Sources` folder from this download into the Xcode project navigator, onto the top-level project entry.
3. In the dialog:
   - ✅ **Copy items if needed**
   - ✅ **Create groups**
   - ✅ Target “ABSPlayer” is checked
4. You should now see the groups `Models`, `Networking`, `ViewModels`, `Views`, and `ABSPlayerApp.swift` in Xcode.

**If you're replacing files from a later update rather than doing a first-time setup:** don't drag new files on top of old ones with the same name still present — macOS will create a numbered duplicate (`File 2.swift`) instead of overwriting, and Xcode will then point at the wrong physical file. Either edit each changed file's content directly in Xcode, or delete the old group first (Move to Trash) and then drag the replacement in fresh.

## 4. Enable background audio

1. Select the project file → Target `ABSPlayer` → **Signing & Capabilities** tab
2. Add **+ Capability** → **Background Modes**
3. Check **Audio, AirPlay, and Picture in Picture**

Without this step, playback will pause when the screen locks or the app goes into the background.

## 5. Signing with a free Apple ID

1. In the same **Signing & Capabilities** tab:
   - **Team:** select your Apple ID; add it in Xcode → Settings → Accounts if needed
   - **Bundle Identifier:** use something unique, for example `de.yourname.absplayer`
2. In `KeychainStore.swift`, set the `service` constant to the same bundle identifier; look for the line containing `com.example.absplayer`.

**Important when using a free Apple ID without the Developer Program:** The app only runs on your device for 7 days. After that, you need to rebuild it once through Xcode by connecting the device and pressing ▶. For a purely private app, this is an acceptable compromise.

## 5b. Set the display name; optional

The name shown below the app icon can be set independently from the internal project name:

1. Project file → Target `ABSPlayer` → **General** tab
2. Set **Display Name** to `Hörregal`.

This makes the app appear as “Hörregal” on the home screen while the Xcode project remains named `ABSPlayer`. Renaming the internal project is fiddly and not worth it.

## 6. Build to your iPhone

1. Connect your iPhone via cable, or set up wireless debugging
2. Select your iPhone as the target device at the top of Xcode, not the simulator — background audio is much more reliable to test on real devices
3. Press ▶
4. On the iPhone, if necessary, go to **Settings → General → VPN & Device Management** and trust your Apple ID once

## 7. Log in inside the app

- Server: `your-server.example.com`; `https://` is added automatically
- API token: from step 1

---

## iPad support

The app is designed for iPhone and iPad. To make sure it can be installed on iPad, iPad needs to be enabled as a supported device for the target:

1. Project file → Target **ABSPlayer** → **General** tab
2. Under **Supported Destinations**, **iPad** should be listed. This is enabled by default for new SwiftUI projects. If not, click **+** and add iPad.
3. Under **Deployment Info**, check iPhone and iPad orientations. For an audiobook player, portrait and landscape are sufficient.

The library grid adapts automatically to the available width — more columns on iPad, even more in landscape — and recalculates cleanly on every rotation. On iPhone portrait, the mini-player hides its secondary transport buttons (skip forward/back, AirPlay) to leave more room for the book title; they reappear automatically on iPad or in iPhone landscape.

```text
Sources/
├── ABSPlayerApp.swift              Entry point
├── Models/                         Codable structs for the Audiobookshelf API
├── Networking/
│   ├── APIClient.swift             All HTTP calls
│   ├── KeychainStore.swift         Secure storage for server URL and token
│   ├── DownloadManager.swift       Multi-track offline downloads and their cached metadata
│   ├── FileDownloader.swift        Underlying URLSession download with progress reporting
│   ├── ImageCache.swift            Two-tier (memory + disk) cover cache
│   ├── NetworkMonitor.swift        Continuous connectivity observation (auto-reconnect)
│   ├── NetworkStatus.swift         One-shot Wi-Fi check and shared offline-error detection
│   └── SyncQueue.swift             Persistent queue for progress updates that failed offline
├── ViewModels/
│   ├── AuthViewModel.swift         Setup screen logic
│   ├── LibraryViewModel.swift      Loads book list and progress, sorting, offline disk cache
│   ├── PlayerCoordinator.swift     Keeps the active session alive across navigation,
│   │                               offline-aware, basis for the mini-player
│   └── PlayerViewModel.swift       AVQueuePlayer, multi-track handling, core sync rule,
│                                   chapters, sleep timer
└── Views/
    ├── SetupView.swift             Server and token input
    ├── RootView.swift              Switches between setup and library
    ├── LibraryView.swift           Book list, search, sort/filter, sections, adaptive grid
    ├── BookDetailScreen.swift      Book detail page, download, mark as heard, play/pause
    ├── BookCoverView.swift         Cover with progress bar and status badges, reused across views
    ├── CachedAsyncImage.swift      AsyncImage replacement backed by ImageCache
    ├── MiniPlayerBar.swift         Persistent floating glass mini-player
    ├── FloatingSearchButton.swift  Expanding search button
    ├── AdaptiveGlassBackground.swift  Shared Liquid Glass styling with material fallback
    ├── AirPlayButton.swift         AirPlay route picker wrapper
    ├── PlayerScreen.swift          Full player, displays the coordinator session
    ├── PlayerView.swift            Audible-style player UI
    ├── CoverColorLoader.swift      Extracts an accent color from the cover
    ├── ChapterListView.swift       Chapter list as a sheet
    └── Haptics.swift               Small haptic feedback helper
```

**Mini-player architecture note:** `PlayerCoordinator` lives in `LibraryView` and survives navigation. Playback is not stopped when leaving the player screen or when the mini-player is temporarily hidden (e.g. behind an expanded search field on iPhone) — it only stops when explicitly opening a different book.

API endpoints used:

| Purpose | Endpoint |
|---|---|
| Libraries | `GET /api/libraries` |
| Book list | `GET /api/libraries/{id}/items` |
| Book details, chapters and progress | `GET /api/items/{id}?expanded=1` |
| Write progress | `PATCH /api/me/progress/{itemId}` |
| Progress for the whole library | `GET /api/me` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio stream | direct `contentUrl` from the track data, with `Authorization: Bearer` header |

## About this project

Hörregal was created with support from Claude by Anthropic.
