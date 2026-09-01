<p align="center">
  <img src="docs/logo.png" alt="Mär app icon" width="128" height="128">
</p>

# Mär

A lightweight, open-source iOS/iPadOS client for **self-hosted audio** — audiobooks, podcasts, music, and internet radio in one app, with one design language and one player.

Mär is **server-first and offline-first**: your library, metadata, covers, and progress live on your own servers and reach the app over **open, standard APIs that need no client-side API keys** — [Audiobookshelf](https://www.audiobookshelf.org/), Subsonic/OpenSubsonic, gpodder/mygpo, plain RSS, and the open Radio Browser catalog. Its foundation is **reliable playback progress sync** across devices, without accidentally resetting a book to 0 — including while fully offline.

> „Mär“ is an old German word for a tale or story — fitting for an audio player. The Xcode project is `Maer.xcodeproj`; “Mär” with the umlaut is the display name.

Mär started as a private replacement for a client that regularly lost playback progress when switching devices. It has since grown into a universal client for the self-hosted, open-source audio ecosystem — built on a provider architecture, deliberately focused: no multi-user support, no server administration, just listening and keeping progress reliably in sync, online or off.

> **Note:** This is a private hobby project without warranty. It is not affiliated with the Audiobookshelf project.

**Home:** <https://maer.fm> · **Source:** <https://codeberg.org/LzS/maer>

## Privacy & Data Security

Mär is built on a simple rule: **your listening is nobody's business.**

- **No account.** Mär has no sign-up, no cloud, no user database. The only logins are the ones to your own servers.
- **No tracking.** No analytics, no ads, and no third-party SDKs — the project has zero external code dependencies.
- **Your data stays yours.** Listening progress, subscriptions and downloads live on your device and on servers you run (Audiobookshelf, Subsonic/Navidrome, Jellyfin, Booksonic, gpodder/oPodSync, Pinchflat). Nothing is sent anywhere else.
- **Network requests only to sources you can see.** Every external service the app can talk to has its own switch under Settings → External Sources & Privacy — the eleven by name: LibriVox, Project Gutenberg, Internet Archive, Jamendo, Podcast Index, Apple Podcasts, Radio Browser, Wikidata / Wikimedia Commons, MusicBrainz / Cover Art Archive, LRCLIB, and covers from podcast hosts. Each switch states what it feeds and what stays when it is off. Which rows appear on the tabs is a separate question, answered under Settings → Rows. The optional built-in app keys for Jamendo/PodcastIndex authenticate the app against those services — they carry no user identity.
- **Credentials stay local.** Server logins, tokens and secrets are stored in the system keychain; logs carry hosts, not secrets, and the OPML export excludes premium/token feeds by default.
- **Don't trust us — read the code.** Mär is GPL-3.0: every claim above is verifiable in this repository.

## Screenshots

| Library | Player | Music |
|---|---|---|
| ![Library](screenshots/iphone_library.png) | ![Player](screenshots/iphone_player.png) | ![Music](screenshots/iphone_music.png) |

| Library (iPad) | Book page (iPad) |
|---|---|
| ![Library on iPad](screenshots/ipad_library.png) | ![Book page on iPad](screenshots/ipad_detail.png) |

| Library (landscape) | Book page (landscape) |
|---|---|
| ![Library in landscape](screenshots/iphone_library_landscape.png) | ![Book page in landscape](screenshots/iphone_detail_landscape.png) |

## Features

- Sign in with username/password or an API token, compatible with both the old and new Audiobookshelf authentication systems
- Library as an adaptive cover grid for iPhone and iPad, self-sizing to always fit the actual screen width without overlap, even across rotation
- **Global search across every source**: one search reaches audiobooks, podcasts, music, and radio at once. A standing scope bar narrows it to Library / Audiobooks / Podcasts / Music / Radio; an empty field shows a browse deck (recent searches, and entry tiles for authors/series/genres, artists, shows, albums); typing yields ranked results per type. The podcast and radio scopes fold in a catalog section — “New Shows” from PodcastIndex/iTunes, stations from Radio Browser — so you can subscribe to or play something you don't have yet. Offline-capable: each source searches its cached content, and results that can't play right now are dimmed and marked
- **Start without a server**: onboarding lets you skip sign-in and start straight away with podcasts (RSS) and local files; sources — Audiobookshelf, a music server, radio, gpodder sync — are added one at a time later under Settings, and their tab appears live
- **Home tab**: a cross-media start screen with Continue, Rediscover (paused for a while / next unfinished book in a series), Discover (usage-driven recommendations), and a dense Latest-Episodes grid
- **Free catalogs** (opt-in): browse rows from the open audio commons — LibriVox and Internet Archive audiobooks, Project Gutenberg, old-time radio plays, netlabel music, digitised 78 rpm records, Jamendo — with genre shelves, day-rotating popular rows, and an honest per-title rights capsule that never guesses
- Sorting by title, author, recently added, or recently listened, with an ascending/descending toggle; sort and filter choices are remembered across app launches
- Filters for all/unfinished/finished books
- “Continue Listening”, “Recently Added”, and “Downloaded” sections
- Haptic Touch context menu on covers for quick actions: play, download, mark as heard
- Progress bar, “Finished” checkmark, and download-status badge directly on each cover; finished books are shown slightly desaturated
- Book detail page with description, narrator, series, genres, publication year, and total duration; download and “Mark as heard” directly from the detail page, with a play/pause button that correctly reflects and controls an already-playing session
- Persistent floating mini-player styled after Apple's Liquid Glass design (iOS 26), with a circular progress ring around the cover; extra transport controls (skip forward/back, AirPlay) appear only on iPad or in landscape, keeping more room for the title on iPhone portrait; automatically restores the last listening session after a full app restart, paused and never auto-playing
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
- Settings screen: sources and per-service sync in one tab-independent place, skip interval, default playback speed for new books, **Smart Rewind** (resume a little earlier after longer pauses), **auto-play the next unfinished book of a series**, appearance override (system/light/dark), Wi-Fi download warning toggle, storage management, notifications, listening statistics, and the app version
- **Sync history** in the settings — one list across every service (Audiobookshelf progress, gpodder, iCloud, music library), with a per-service “last checked” line and a ring of the actual changes, errors, and mass-delete guard events; a clean run that changed nothing stays visible without cluttering the ring
- **Drive mode**: a big-button full-screen layout for the car mount — manual or automatic entry when your chosen car audio route connects (no extra permissions); screen stays awake, Siri shortcut included
- **Listen log**: a per-person podcast listening history that survives unsubscribing and feed rotation
- The app restarts on the **last selected tab**, and a temporarily unreachable server never throws you off your tab
- **Siri & Shortcuts**: “Continue listening in Mär” and “Play *book* in Mär” (book names come from the offline library cache), plus a home-screen quick action that resumes the last played book
- **CarPlay**: audiobook tabs (Continue Listening / Downloaded / Library), plus a Podcasts tab and a Music tab once those sources are set up, each with cover thumbnails and the system Now Playing screen, sharing the phone's playback session — works on a cold start in the car, falling back to the offline cache; testable in the simulator out of the box, real cars need Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay)
- Adaptive light and dark design with a **dark-gray brand accent**; each media type carries its own color on the tab selector — audiobooks orange, podcasts purple, music red, radio cyan. The Liquid Glass chrome (mini player, search, toolbar buttons) takes a soft pastel wash of the current cover color in light mode, and the mini player dips off-screen and springs back when switching books
- Performance: grid cells decode a small derived thumbnail instead of the full cover — smooth scrolling and far less memory with large libraries; the book list is fetched in Audiobookshelf’s minified format
- **Accessibility**: full Dynamic Type support up to the accessibility text sizes — control rows reflow to a two-column grid, fixed-width tiles gain lines, and hard-coded metrics scale via `@ScaledMetric`; VoiceOver labels on all controls and 44 pt tap targets; verified across device sizes from the 375 pt class to iPad in both orientations
- Hardening: free-space check before downloads start, magic-byte container detection with automatic file-extension repair (unit-tested), automatic recovery when a track fails mid-playback instead of silent stalling, VoiceOver labels on all transport controls

## Podcasts

Version 2.0 makes Mär a full **podcast client** alongside audiobooks. Podcasts are a separate media type behind the same provider protocol, so audiobook playback and sync stay untouched; a dedicated podcast tab appears only once you have subscriptions.

- **Three subscription sources, reconciled:** local **RSS** feeds, opt-in **Audiobookshelf** podcast libraries, and a self-hosted **gpodder/mygpo** server (e.g. [oPodSync](https://github.com/kd2org/opodsync)) as an equal backend next to iCloud and ABS. Subscriptions, unsubscribes, and play state are kept in one clean, reconciled state across all three — a robust unsubscribe removes a feed from every source at once
- **Apple Podcasts import** of your existing subscriptions
- **Apple-Podcasts-style home:** a “Continue” row of rich featured cards (remaining time · last played · chapter), usage-driven recommendations, the up-next queue, a premium row, downloaded episodes, and a “Recently updated” show grid with a red badge for new unheard episodes
- **Usage-driven recommendations:** language-aware and themed from your own library and listening time, expanded by author/publisher and round-robin mixed so no single publisher dominates
- **Per-show settings:** inbox mode, keep-latest-N with automatic trimming of old downloads, auto-download of new episodes, and per-show new-episode notifications
- **Premium feeds** via per-feed HTTP Basic auth, stored in the keychain
- **Rich metadata** from RSS / Podcasting 2.0 and the PodcastIndex API: seasons, episode type, explicit flag, guests/persons, transcripts, funding links, categories
- **Background refresh** (`BGAppRefreshTask`) with bundled per-show notifications, offline downloads, a play queue, chapters, high-resolution feed covers, CarPlay, and a home-screen “Up Next” widget
- Listening-history bridging between RSS and ABS podcast episodes (shared progress, optional server push)

## Music

Version 2.1 adds **music** as a third media type, for **Subsonic / OpenSubsonic**-compatible servers (Navidrome, Gonic, Airsonic). Like podcasts it sits behind the same provider protocol, so audiobook and podcast playback stay untouched; a Music tab appears once a server is configured under Settings → Music.

- **Media-type-specific browsing** (not the audiobook grid): full-size playlist cards with a real cover mosaic on top, a grouped library list (Artists · Albums · Songs · Playlists · Downloaded), and "Recently Played" / "Recently Added" shelves. An album is one multi-track item — tapping a track plays the whole album from that point through the same player as everything else.
- **Playlists**: create, rename, and delete server playlists; add songs or whole albums from any context menu ("Add to Playlist", with a new-playlist flow); remove rows index-precisely. Continue-listening works for playlists AND albums (server bookmarks on Subsonic, cross-device).
- **Jellyfin (beta)** as a second music backend behind the same surface — albums, artists, playlists, search, lyrics, favorites; active when it is the only configured music source. Still in verification against a real server.
- **Jellyfin audiobooks (built, not yet verified)** — a library with `CollectionType: books` shows up as an audiobook library, and its entries play with a real listening position that travels to the server and back. **Two measured limits, and they are the server's, not ours:** a book on Jellyfin is exactly **one file** (a folder of chapter files produces no entry at all — measured against Jellyfin 10.11.11 with Bookshelf 13.0.0.0), and there are **no chapters** (Jellyfin generates none for `AudioBook`). The listening position travels over `UserData`, not over playback sessions — the session route was measured not to persist anything. **No checkmark until this is validated against a live server.**
- **Booksonic mode**: mark a Subsonic source as audiobooks and its albums become books (chapters, progress, continue-listening) in the audiobook tab.
- **Artist pages** (OpenSubsonic): artist image and biography, top songs (tap to play), and similar artists limited to those that actually exist in your own library. All best-effort — a server without a metadata agent simply shows fewer sections.
- **Album detail**: notes, year · genre, a favorite (star) toggle, and offline download of the whole album. A high-resolution front cover is fetched from the **Cover Art Archive** when the album carries a MusicBrainz ID (respecting its User-Agent and 1 request/second policy).
- **Lyrics in the player**: server-first (`getLyricsBySongId`), with the open **LRCLIB** service as a fallback (a ±5 s duration check guards its fuzzy matching); synced lyrics highlight the current line and follow playback with tap-to-seek, unsynced lyrics render as static text. Results — including negative hits — are cached on disk, so the button and panel stay instant and work offline.
- **Favorites** (star / unstar) and **scrobble on play**: the server's own play counts, and Last.fm / ListenBrainz when the server forwards scrobbles.
- Deliberately no server-side position sync for music (it doesn't need one); playback, downloads, and a CarPlay music tab use the shared core. The metadata endpoints are verified against the OpenSubsonic extensions where available.

## Radio

Mär also plays **internet radio**, a fourth media type behind the same provider protocol. A Radio tab appears once the source is enabled under Settings → Sources → Radio.

- **Two sources:** the open **[Radio Browser](https://www.radio-browser.info/)** catalog (searchable, no account) and your **own stream URLs** (e.g. an AzuraCast mount) added by hand. Codec/bitrate variants of the same station are folded to a single result, with a quality picker on the station page and in the live player.
- **National & regional discovery**: popular stations of your own country plus a state/region picker; station detail pages (homepage, bitrate, codec, tags, similar stations) via the context menu.
- **Honest live abstraction:** a live stream has no duration, no seek, no progress, and no download, so the player switches to a live layout — a LIVE marker instead of a scrubber, play/pause only, and a clock-based sleep timer. None of the progress machinery runs, and radio never enters the up-next queue.
- **ICY now-playing:** the current song from the stream's ICY metadata shows in the player (under the station name) and on the lock screen.
- **Favorites, your own stations, and a recent ring**, stored on the device; a station-colored artwork placeholder (with the station favicon when the stream ships one) is shared between the rows and the player, so it never upscales a tiny favicon on the big player.

## Works with

Mär talks to servers through their standard APIs, so it works with more than one implementation of each. Only what has actually been verified is stated as such; “should work” means standard-compatible but not tested here — no compatibility promises for servers that haven't been tried.

- **Audiobookshelf** — audiobooks and podcasts (verified, daily use).
- **Navidrome** (Subsonic/OpenSubsonic) — verified: daily use plus an automated 9/9 protocol probe (ping, artists, albums, search, cover art, streaming, playlists).
- **oPodSync** (gpodder/mygpo) — verified, including the device registration stricter servers require.
- **Booksonic** — should work via the audiobooks mode of a Subsonic source; the client negotiates the older API version automatically (books live in the folder the web UI exposes). Not yet verified against a live Booksonic server.
- **Funkwhale** — should work: its Subsonic dialect ships numeric IDs and partial endpoints (handled leniently); sign in with a Funkwhale **application token** as the password. Not yet verified against a live Funkwhale instance.
- **Jellyfin** — built in as a second music backend, currently **in verification** against a real server; treat it as beta.
- **RSS / Podcasting 2.0** feeds, the **PodcastIndex** directory, and the open **Radio Browser** catalog for stations.
- **PodFetch** — verified as an RSS/gpodder family member (the tooling agent's matrix, wave 2).
- **Gonic** and **Airsonic** — verified via the Subsonic protocol probe (the tooling agent's matrix, wave 2).
- **Pinchflat** — verified as a plain RSS feed family (12/12 real-feed probe, the tooling agent's matrix, wave 3): its per-channel feeds play like any podcast.
- **Pinchflat server binding** — verified end-to-end against a live Pinchflat instance: connect with server address + route token (+ optional Basic Auth), the channel list (`/sources/opml`) mirrors as its own group, new/removed channels follow the server, per-channel hide as opt-out, provenance shown as "YouTube". Credentials live in the keychain; the mirrored group stays out of gpodder sync (each device mirrors its own).
- Deliberately **not** verified: **Podsync** (needs the user's own Google API key — out of scope for a probe) and **ytdl-sub** (produces no RSS; not part of this family).

Only rows the compatibility matrix actually covers are claimed as verified; everything else is "should work" at best. Source of truth for the verified rows is the compatibility matrix in the delivery repo.

## Core sync rule

This is the heart of the app. A user-triggered seek action — scrubber, chapter jump, ±30s, or lock screen control — is treated as intentional and synced immediately, even backwards. A warning dialog only appears if progress drops by more than 120 seconds **without user action**, for example due to a faulty client reset. If the user cancels, playback jumps back to the last stored position.

When switching devices, the app briefly checks the server before each playback start. The entry with the newer timestamp wins: if another device wrote last, its position is adopted — even if it is **further back** (e.g. after deliberately rewinding there). On older servers without a timestamp, only a further-ahead server position is adopted. True simultaneous listening on two devices is not covered; in that case, the last writer wins.

Every progress write always sends a complete record (current time, duration, and finished status together) rather than a partial update — a partial update leaves the server to guess what to do with the fields it wasn't given, which previously caused real progress loss when only the finished flag was toggled.

## Intentionally not included

Multi-user support, metadata editing, and server/library administration. Also not built (today): an equalizer and an Apple Watch app.

## Requirements

- Xcode with an iOS 26 SDK available (needed to build the app, which uses Apple's Liquid Glass API)
- Deployment target **iOS/iPadOS 26.5** (minimum runtime version)
- A source of audio — but **no server is required to start**:
  - you can **begin without any server** and use podcasts (RSS) and imported local files right away
  - **Audiobookshelf** for audiobooks and podcasts — with your account credentials or an API token
  - and/or a **Subsonic/OpenSubsonic**-compatible music server (Navidrome, Gonic, Airsonic) for the Music tab
  - **internet radio** needs no server — the public Radio Browser catalog, plus any of your own stream URLs
  - podcast subscriptions can additionally sync through a self-hosted **gpodder/oPodSync** server (optional; iCloud and Audiobookshelf are the other backends)
- An Apple ID for signing; a free Apple ID is sufficient, see the note on 7-day signing below

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). Up to v2.1 Mär was offered under
the MIT license; from this commit on GPL-3.0-or-later applies. LICENSE files
in older history are historical artifacts.

Mär is GPL-3.0. Additional terms under GPL-3.0 section 7 apply — an additional
permission for distribution through application distribution channels, and a
reservation of the name and icon: see
[LICENSE-ADDITIONAL-TERMS](LICENSE-ADDITIONAL-TERMS). For distribution through
the App Store a custom end-user agreement applies instead of Apple's standard
one: [docs/EULA.md](docs/EULA.md). The source of every released version stays
available at <https://codeberg.org/LzS/maer>.

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

The repository ships the complete Xcode project — nothing needs to be assembled.
**Mär builds without any API keys** (two optional app keys for Jamendo and
PodcastIndex are read from `Config/AppKeys.local.xcconfig` if that file exists;
without it those two rows simply stay away) and it has **no third-party
dependencies** — no package manager step, nothing to resolve.

1. Clone the repo and open **`Maer.xcodeproj`** (Xcode with an iOS 26 SDK).
2. **Signing** (target `Maer` → Signing & Capabilities):
   - **Team:** your Apple ID — a free one is enough (see note below)
   - **Bundle Identifier:** change it to something unique, e.g. `de.yourname.maer`, on BOTH targets (`Maer` and `MaerWidgetsExtension` — the widget ID must stay a child of the app ID, e.g. `de.yourname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift`, set the `service` constant to the same bundle identifier.
   - **App Group:** replace the group identifier in both targets' `.entitlements` files and in `Sources/Models/WidgetShared.swift` with one of your own (e.g. `group.de.yourname.maer`) — a group registered to someone else's team will not sign.
3. Connect your iPhone, select it as the run destination (background audio is far more reliable to test on a real device than in the simulator), press ▶.
4. On the iPhone, trust your Apple ID once under **Settings → General → VPN & Device Management** if asked.

Background audio, the widget extension target, the CarPlay scene, and iPhone/iPad support are already configured in the project.

**Free Apple ID without the Developer Program:** the app runs for 7 days per install, then rebuild once via Xcode. **CarPlay in a real car** additionally needs Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay, paid account) — the CarPlay simulator (`I/O → External Displays → CarPlay`) works without it.

## 3. Log in inside the app

- Server: `your-server.example.com`; `https://` is added automatically
- Then either username + password, or an API token from step 1

---

## iPad support

iPhone and iPad are both enabled in the project. The library grid adapts automatically to the available width — more columns on iPad, even more in landscape — and recalculates cleanly on every rotation. On iPhone portrait, the mini-player hides its secondary transport buttons (skip forward/back, AirPlay) to leave more room for the book title; they reappear automatically on iPad or in iPhone landscape.

```text
Sources/
├── MaerApp.swift                   Entry point + AppDelegate for background download events
├── AppSession.swift                Process-wide session (player/library shared with CarPlay)
├── AppShortcuts.swift              Siri App Intents (continue listening, play a specific book)
├── Providers/
│   ├── AudioProvider.swift         Protocol every audio source implements (login, library,
│   │                               search, stream, download, sync) — the core sees only this
│   ├── ABSProvider.swift           Audiobookshelf as the first provider
│   ├── LocalProvider.swift         Imported local audio files (no server)
│   ├── LocalLibrary.swift          Local file index + AVAsset metadata extraction
│   ├── SubsonicProvider.swift      Subsonic/OpenSubsonic music (Navidrome, Gonic, Airsonic)
│   ├── RadioProvider.swift         Internet radio (radio: namespace), Radio Browser + own URLs
│   ├── RSSProvider.swift           Podcasts: RSS episodes mapped to library items
│   ├── MaerPlaylists.swift         Mär playlists: the SECOND playlist type, mixing every id
│   ├── ABSPodcastProvider.swift    Audiobookshelf podcast libraries (opt-in source)
│   ├── PodcastSubscriptions.swift  Feed store + XMLParser-based RSS/Podcasting-2.0 parser
│   ├── PodcastSubscriptionSync.swift  Reconciled local ↔ ABS subscription mirroring
│   ├── PodcastDirectory.swift      Discovery via PodcastIndex + iTunes charts
│   ├── PodcastRecommendationsStore.swift  Usage-driven, themed recommendation ranking
│   ├── ProviderSearch.swift        SearchableProvider capability + per-source search
│   ├── PlayQueue.swift             Global cross-media up-next queue (all media types)
│   └── PodcastImport.swift         Apple Podcasts subscription import
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay tabs (audiobooks + podcasts + music) + Now Playing
├── Models/
│   ├── AudiobookshelfModels.swift  Codable structs for the Audiobookshelf API
│   ├── SubsonicModels.swift        Codable structs for the Subsonic/OpenSubsonic API
│   ├── RadioModels.swift           Foundation-only radio core (mapping, ICY parse, store)
│   ├── MediaType.swift             The four media types (audiobooks/podcasts/music/radio)
│   ├── SyncRules.swift             Pure, unit-tested sync decision rules + multi-track time math
│   ├── SyncHistory.swift           Pure sync-history entries + ring buffer
│   ├── HomeSections.swift          Home aggregation (recency, fair interleave)
│   ├── RediscoverSections.swift    Rediscover picks (paused / unheard / next in series)
│   ├── SearchModels.swift          Search result/ranking types
│   ├── AppStorageKeys.swift        Central UserDefaults keys, one activation answer per source
│   ├── SourceMap.swift             Pure: the five areas and what each needs (map states)
│   ├── MaerPlaylistMerge.swift     Pure: per-list merge, rescued version, tombstones
│   └── PodcastAutoDownloadRules.swift  Pure: what the automatic download may clean up
├── Networking/
│   ├── APIClient.swift             All HTTP calls
│   ├── AppUserAgent.swift          THE one identity the app shows foreign servers
│   ├── MaerPlaylistCloudSync.swift Mär playlists across your own devices (iCloud KV)
│   ├── KeychainStore.swift         Secure storage for server URL and token
│   ├── DownloadManager.swift       Multi-track offline downloads and their cached metadata
│   ├── FileDownloader.swift        Shared background URLSession download with progress reporting
│   ├── ImageCache.swift            Cover cache: memory + purgeable disk + persistent store for downloaded books
│   ├── SubsonicClient.swift        Subsonic/OpenSubsonic API (token+salt auth, streaming, lyrics)
│   ├── CoverArtArchive.swift       High-res album covers via MusicBrainz ID (rate-limited)
│   ├── RadioBrowserClient.swift    Radio Browser catalog client (mirror fallback)
│   ├── SyncHistoryStore.swift      Persisted sync history + per-service "last checked"
│   ├── NetworkMonitor.swift        Continuous connectivity observation (auto-reconnect)
│   ├── NetworkStatus.swift         One-shot Wi-Fi check and shared offline-error detection
│   ├── BookmarkQueue.swift         Offline queue + cache for bookmark create/delete
│   ├── SyncQueue.swift             Persistent queue for failed progress updates (storage/API
│   │                               behind protocols for testability)
│   ├── Retry.swift                 Backoff retry for transient network errors
│   ├── URLSession+Maer.swift       Shared session with sane request/resource timeouts
│   ├── GPodderClient.swift         gpodder/mygpo API client (login, subscriptions, episodes)
│   ├── GPodderSync.swift           3-way reconcile of gpodder subscriptions + play actions
│   ├── PodcastCloudSync.swift      iCloud key-value sync of local subscriptions
│   ├── PodcastFeedAuth.swift       Per-feed HTTP Basic auth for premium feeds (keychain)
│   ├── PodcastRefreshService.swift Background feed refresh + new-episode notifications
│   └── PodcastServerSave.swift     Deferred server-side save of streamed feed episodes
├── ViewModels/
│   ├── AuthViewModel.swift         Setup screen logic
│   ├── GlobalSearchModel.swift     Cross-source search (fan-out, debounce, partial results)
│   ├── LibraryViewModel.swift      Loads book list and progress, sorting, series grouping,
│   │                               offline disk cache
│   ├── PlayerCoordinator.swift     Keeps the active session alive across navigation,
│   │                               offline-aware, basis for the mini-player
│   ├── PlayerViewModel.swift       AVQueuePlayer, multi-track queue, seek/skip, chapters
│   ├── PlayerViewModel+Sync.swift  Sync policy: timer, reentrancy guard, conflicts, reconcile
│   ├── PlayerViewModel+SleepTimer.swift   Sleep timer incl. volume fade
│   └── PlayerViewModel+NowPlaying.swift   Lock screen commands, NowPlaying info, artwork
└── Views/
    ├── SetupView.swift             First screen: the map of areas + start without a
    │                               server; holds ABSLoginForm/ABSLoginPage (the ONE
    │                               Audiobookshelf sign-in, also used behind "Connect")
    ├── SourceMapCard.swift         THE map of areas — first screen AND the sources
    │                               overview in the settings, plus SourceAreaPage
    ├── SettingsView.swift          Playback, appearance, storage, sync, server settings
    ├── RootView.swift              Switches between setup and library
    ├── LibraryView.swift           Book list, sort/filter, sections, adaptive grid
    ├── HomeView.swift              Cross-media start tab (continue/rediscover/discover/latest)
    ├── SearchScreen.swift          Full-page global search (scope bar, browse deck, catalog)
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
    ├── Haptics.swift               Small haptic feedback helper
    ├── MediaTabBar.swift           Home/Audiobooks/Podcasts/Music/Radio media-type switcher
    ├── MediaTile.swift             Shared grid tile (home, latest episodes, recommendations)
    ├── MediaRowContent.swift       Shared list-row layout (podcast episodes, books, stations)
    ├── SyncHistoryView.swift       Settings: sync history ("last checked" + change ring)
    ├── ABSSourceView.swift         Audiobookshelf source page (access, sync)
    ├── SubsonicSourceView.swift    Music source page (server, credentials, sync)
    ├── RadioSourceView.swift       Radio source page (enable, own stream URLs)
    ├── PodcastsView.swift          Podcast home (continue, recommendations, queue, shelves)
    ├── PodcastSourceView.swift     Add/import podcasts and pick subscription sources
    ├── Podcasts/                   Show, episode, queue, discover, per-show settings, cards
    ├── Music/                      Music home, album, artists, playlists, lyrics panel
    └── Radio/                      Radio tab, station rows, shared radio artwork
```

**Mini-player architecture note:** `PlayerCoordinator` lives in `LibraryView` and survives navigation. Playback is not stopped when leaving the player screen or when the mini-player is temporarily hidden — it only stops when explicitly opening a different book.

API endpoints used:

| Purpose | Endpoint |
|---|---|
| Libraries | `GET /api/libraries` |
| Book list (progressive paging) | `GET /api/libraries/{id}/items?minified=1&limit=&page=` |
| Continue / Recently-Added shelves | `GET /api/libraries/{id}/personalized` |
| Book details, chapters and progress | `GET /api/items/{id}?expanded=1` |
| Write progress | `PATCH /api/me/progress/{itemId}` |
| Progress for the whole library | `GET /api/me` |
| Password sign-in | `POST /login` |
| Search (books/authors/series) | `GET /api/libraries/{id}/search?q=` |
| Bookmarks | `GET /api/me`, `POST/DELETE /api/me/item/{id}/bookmark…` |
| Cover | `GET /api/items/{id}/cover?token=...` |
| Audio stream | direct `contentUrl` from the track data, with `Authorization: Bearer` header |
| gpodder/mygpo sync | `POST /api/2/auth/{user}/login.json`, `GET/POST /api/2/subscriptions/{user}/{device}.json`, `GET/POST /api/2/episodes/{user}.json` |

Podcasts additionally talk to external **RSS feeds**, the **PodcastIndex** API and **iTunes** charts (discovery/metadata, optional key), and your self-hosted **gpodder/mygpo** server.

Music talks to your **Subsonic/OpenSubsonic** server (`ping`, `getAlbumList2`, `getAlbum`, `getArtists`, `getArtist`, `getArtistInfo2`, `getAlbumInfo2`, `getTopSongs`, `search3`, `getPlaylists`, `getLyricsBySongId`, `stream`, `getCoverArt`, `scrobble`, `star`), the **Cover Art Archive** (high-resolution covers via MusicBrainz ID), and **LRCLIB** (open lyrics fallback).

Radio uses the open **[Radio Browser](https://www.radio-browser.info/)** catalog (`/json/stations/search`, mirror fallback across `de1`/`at1`/`nl1`) and plays your own stream URLs directly; the live song comes from the stream's own ICY metadata.

## About this project

Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable), plus locally hosted open-weight models — qwen3, devstral and OpenAI's open gpt-oss weights — run via Ollama for tooling and test harnesses.
