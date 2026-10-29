<p align="center">
  <img src="docs/logo.png" alt="Mär app icon" width="128" height="128">
</p>

# Mär

A lightweight, open-source iOS/iPadOS client for **self-hosted audio**: audiobooks, podcasts, music, and internet radio in one app, with one design language and one player.

Mär is **server-first and offline-first**: your library, metadata, covers, and progress live on your own servers and reach the app over **open, standard APIs that need no client-side API keys**: [Audiobookshelf](https://www.audiobookshelf.org/), Subsonic/OpenSubsonic, Jellyfin, gpodder/mygpo, plain RSS (including the channel feeds a Pinchflat instance mirrors), and the open Radio Browser catalog. Its foundation is **reliable playback progress sync** across devices, without accidentally resetting a book to 0, including while fully offline.

> „Mär“ is an old German word for a tale or story, fitting for an audio player. The Xcode project is `Maer.xcodeproj`; “Mär” with the umlaut is the display name.

Mär started as a private replacement for a client that regularly lost playback progress when switching devices. It has since grown into a universal client for the self-hosted, open-source audio ecosystem, built on a provider architecture, deliberately focused: no multi-user support, no server administration, just listening and keeping progress reliably in sync, online or off.

> **Note:** This is a private hobby project without warranty. It is not affiliated with the Audiobookshelf project.

**Home:** <https://maer.fm> · **Source:** <https://codeberg.org/LzS/maer>

## Privacy & Data Security

What leaves the device, where it goes, and what stays. Every statement below can be checked in this repository.

- **No account with this project.** Mär has no sign-up, no service of its own and no user database. It signs in only where you enter a login: your own servers, a Mär sync service you host yourself, a premium podcast feed, and, once for an import, Pocket Casts.
- **No tracking.** No analytics, no ads and no third-party SDKs: the project has no external code dependencies. Only builds from Xcode keep MetricKit's daily reports on the device for a measurement page and send them nowhere; TestFlight and App Store builds do not receive them and ask the App Store nothing.
- **On the device.** Listening positions, subscriptions, playlists, statistics, the listening history and the library live in one database file; downloads are files beside it; logins are in the keychain. The log of playback notices keeps at most 200 lines of the last seven days in a file of its own and does not leave the device. What travels between your devices is named in the next three points.
- **Requests to outside services, each with a switch.** Every external service that is not one of your own servers has its own switch under Settings → External Sources & Privacy, eleven by name: LibriVox, Project Gutenberg, Internet Archive, Jamendo, Podcast Index, Apple Podcasts, Radio Browser, Wikidata / Wikimedia Commons, MusicBrainz / Cover Art Archive, LRCLIB, and covers from podcast hosts. Podcast Index appears there only when a key is set, the built-in one or your own; without a key the podcast search uses Apple's directory. Each switch states what it feeds and what stays when it is off. Which rows appear on the tabs is a separate question, answered under Settings → Rows. The optional built-in app keys for Jamendo and Podcast Index identify the app to those services, not you. Outside that page the app contacts Pocket Casts during an import you start.
- **iCloud, on unless you turn it off.** The switch "iCloud" under Settings, Sync is on by default and acts on a device signed in to iCloud. Through iCloud's private database (CloudKit), one record each: listening positions of podcasts, catalog titles and local files; your listening statistics; your Mär playlists; and your choices: the podcast subscriptions with their feed addresses, premium marks and blocked feeds, sorts and filters, radio favourites and the stations you entered, recent searches and stations, hidden titles, the item played last, playback speeds and skip intervals, appearance, notification settings, tab, source and row settings, per-show podcast settings, and the addresses of servers that once worked (never their logins), so your other device can offer them under its address field. Through Apple's key-value store: the "playing on another device" claim; the records above while the device has no iCloud account, before the first CloudKit round and when CloudKit refuses a write; and what a device on an earlier build writes there is read. The logins of premium feeds travel in the iCloud keychain. A feed address that carries its token keeps it, and travels with the subscriptions. The logins of your servers stay on the device. That data goes to Apple under your account and Apple's terms.
- **A sync service of your own, only if you set one up.** Under Settings, Sync, Mär can be pointed at a Mär sync service you host yourself (its own repository, [maer-sync](https://codeberg.org/LzS/maer-sync), one SQLite file, and since v0.2.0 two implementations of one contract: the Rust build is what gets deployed, the Python one stays in the tree as the way back). Signing in asks the service for its key and the account's salt and sends only a proof made from the password; the password itself neither travels nor is kept, and the token the service returns stays in this device's keychain. From the moment you sign in until you sign out, these travel to the service instead of iCloud: listening positions of podcasts, catalog titles and local files, the playback claim, the listening statistics, your Mär playlists and your choices with the subscriptions, and the logins of premium feeds, sealed for your other devices. The documents are encrypted on the way and stored on your host as they arrive; only the feed logins are sealed there. The service tells your other device about a change instead of waiting to be asked. This project runs no such service. A write the service refuses is shown on the Sync page with the service's own sentence.
- **Logins and where they show.** Server passwords, tokens and keys are kept in this device's keychain; the logins of premium feeds travel as named above. Some servers take their token inside the address of a request, so it appears in that server's logs and in the logs of any proxy in front of it: Audiobookshelf in cover and author image links, Subsonic in every request, Jellyfin in stream and cover links, Pinchflat in the channel list address. The app's own logs carry hosts, item ids and public stream addresses, no token. The OPML export leaves premium and token feeds out by default.
- **Importing from other apps.** Imports from Apple Podcasts, Overcast, AntennaPod and OPML files read a file you choose on the device. The Pocket Casts import signs in to Pocket Casts once with the e-mail address and password you enter, reads the subscriptions and listening states of your own account, and discards the login when it finishes; it uses an interface Pocket Casts does not document officially. Imported subscriptions then travel like any other subscription.
- **Read the code.** Mär is GPL-3.0-or-later with additional terms (see License below); every statement above can be checked in this repository.

## Screenshots

Version 3.5 (56) in the simulator, against real sources (an Audiobookshelf and a gonic test instance, public podcast feeds and radio stations), German interface.

| Start | Podcasts | Podcast page | Album | Search |
|---|---|---|---|---|
| ![Start](screenshots/iphone_home.jpg) | ![Podcasts](screenshots/iphone_podcasts.jpg) | ![Podcast page](screenshots/iphone_podcast_page.jpg) | ![Album](screenshots/iphone_album.jpg) | ![Search](screenshots/iphone_search.jpg) |

| Start (iPad) | Podcasts (iPad) | Music (iPad) |
|---|---|---|
| ![Start on iPad](screenshots/ipad_home.jpg) | ![Podcasts on iPad](screenshots/ipad_podcasts.jpg) | ![Music on iPad](screenshots/ipad_music.jpg) |

| Playlist (iPad) | Player (iPad) | Radio (iPad) |
|---|---|---|
| ![Playlist on iPad](screenshots/ipad_playlist.jpg) | ![Player on iPad](screenshots/ipad_player.jpg) | ![Radio on iPad](screenshots/ipad_radio.jpg) |

| Start (iPhone Duo, open) | Podcasts (iPhone Duo, open) |
|---|---|
| ![Start on the open iPhone Duo](screenshots/duo_open_home.jpg) | ![Podcasts on the open iPhone Duo](screenshots/duo_open_podcasts.jpg) |

| Podcast page (iPhone Duo, open) | Playlist (iPhone Duo, open) |
|---|---|
| ![Podcast page on the open iPhone Duo](screenshots/duo_open_podcast_page.jpg) | ![Playlist on the open iPhone Duo](screenshots/duo_open_playlist.jpg) |

| Audiobooks (iPhone Duo, folded) | Radio (iPhone Duo, folded) |
|---|---|
| ![Audiobooks on the folded iPhone Duo](screenshots/duo_folded_audiobooks.jpg) | ![Radio on the folded iPhone Duo](screenshots/duo_folded_radio.jpg) |

## Features

- Sign in with username/password or an API token, compatible with both the old and new Audiobookshelf authentication systems
- Library as an adaptive cover grid for iPhone and iPad, self-sizing to always fit the actual screen width without overlap, even across rotation
- **Global search across every source**: one search reaches audiobooks, podcasts, music, and radio at once. A standing scope bar narrows it to Library / Audiobooks / Podcasts / Music / Radio; an empty field shows a browse deck (recent searches, and entry tiles for authors/series/genres, artists, shows, albums); typing yields ranked results per type. The podcast and radio scopes fold in a catalog section (“New Shows” from PodcastIndex/iTunes, stations from Radio Browser), so you can subscribe to or play something you don't have yet. Offline-capable: each source searches its cached content, and results that can't play right now are dimmed and marked. An author, a series or the authors, series or genres of the library opened from the search open their page in the Audiobooks tab, and going back returns to the search with its query and results
- **Start without a server**: the first screen shows the map of areas; radio, podcasts (RSS), the open catalogs and local files work right away, and servers (Audiobookshelf, a music server, gpodder sync, a Mär sync service) are added one at a time later under Settings, where the same map stands. The setup screen and Next Steps list every server Mär is tested with, each with a short page: what it does, what it needs, what you enter in Mär, and links to its documentation and source code
- **Home tab**: a cross-media start screen with Keep Listening, Up Next, Listen Again (the music you started: albums, playlists, songs), Latest Episodes, Recently Added, Rediscover (paused for a while / next unfinished book in a series), Recommended, and Discover rows for music and for audiobooks and radio plays; each row can be switched off under Settings → Rows
- **Open catalogs** (on from the start, each row can be switched off): browse rows from the open audio commons: LibriVox and Internet Archive audiobooks, Project Gutenberg, old-time radio plays, netlabel music, digitised 78 rpm records (only along curated subject shelves), Jamendo (with a key), with genre shelves, day-rotating popular rows, the Internet Archive's notice once at the top of its surfaces, and each title's rights on its own page, never guessed. A Browse page, reached from Start and from each tab for its own kind, shows each catalog as a row of covers with its arrow onto the catalog's page, and every catalog page can play something at random
- Sorting by title, author, recently added, or recently listened, with an ascending/descending toggle; sort and filter choices are remembered across app launches
- Filters for all/unfinished/finished/downloaded books
- “Keep Listening”, “Downloads”, “Recently Added” and “All Books” sections; with a server, a row of tiles for Series, Authors and Local Files (Series and Authors open a page of every group with its count, a group opens its books); without a server, Local Files stands as a row; the Listening History is the last row of the tab
- Haptic Touch context menu on covers for quick actions: play, play next, play last, mark as finished or unfinished, and hide a title from Keep Listening
- Progress bar, “Finished” checkmark, and download-status badge directly on each cover; finished books are shown in gray
- Book detail page with description, narrator, series, genres, publication year, and total duration; download and “Mark as Finished” directly from the detail page, with a play/pause button that correctly reflects and controls an already-playing session
- Persistent floating mini-player styled after Apple's Liquid Glass design (on iOS 26 and later; earlier systems get the system material), with a circular progress ring around the cover; the skip buttons appear when the bar is at least 360 points wide and drop out on iPhone portrait to keep more room for the title, while AirPlay stays; automatically restores the last listening session after a full app restart, paused and never auto-playing
- Full player as a rounded Liquid Glass sheet floating above the library. Drag it down (grab handle or side zones) to dismiss back to the mini-player, with the library showing through the glass during the pull; large cover, cover-derived gradient background, chapter markers directly on the scrubber, play/pause/scrub, configurable skip interval (15/30/60 s for spoken word, 5/10/15/30 s for music, also applied to lock screen and mini-player buttons), playback speed remembered per book, sleep timer with fixed minutes or until chapter end, AirPlay, “Mark Finished”, and subtle haptic feedback; in landscape (iPhone and iPad) the cover moves next to the controls
- Glass pill for playback and sync notices above the mini-player or in the full player: a short notice (“Adopted server position”, “Conflict detected”) hides after a few seconds, a notice that stopped playback (a title that could not load, an unreadable download without network) shows briefly too, and then the mini player names it on its second line, for example “not reachable” in place of the time, until playback starts again or another title takes over, and “Waiting for the network…” stays until the stream runs again; routine notes such as “Progress saved” go only into the log. A tap on the pill opens the log of recent notices with title and time, also under Settings → Notices; it keeps at most 200 lines of seven days on this device. In the full player the pill sits in free space beside the controls and never covers a button
- Background audio, lock screen and Dynamic Island display including cover artwork
- **Multi-track playback**: audiobooks split across several audio files (not converted to a single M4B) play back-to-back seamlessly, with correct chapter and progress handling across the whole book
- **Offline download** per book, manually triggered with a Wi-Fi warning; downloads every track of a book, not just the first, continues while the app is in the background, shows a live progress ring on the cover badge, and caches its chapters/metadata locally. A downloaded book opens and plays fully offline, without needing to reach the server just to show its chapter list. A download from a server that gives none of its downloads a byte for two minutes, while the app is open and online, ends with a notice and continues where it stopped on the next try
- **Offline library**: when the server is unreachable, the library still shows every book from its database, with the books that are not downloaded dimmed and a banner saying so; covers of downloaded books are stored persistently, so they survive iOS cache purges; covers larger than the device needs are scaled down once and kept as JPEG
- **Offline sync queue**: a progress update that fails to send, whether offline or due to a server error, is queued in the app's database (the entry is written before the call returns, so an app killed right after keeps it) and automatically retried on the next app start or as soon as the connection returns; before flushing, the queue reconciles against the server so a stale queued position never overwrites a newer one from another device. A position queued under one Audiobookshelf server waits for that server: after switching to another, it is neither sent there nor dropped, and once a device has known two servers, no library load clears the positions of the other one's books
- Automatic reconnect detection: the library and any queued sync updates refresh by themselves once the connection comes back, without needing to background/foreground the app
- **Safe progress sync**; see Core sync rule below
- Multi-device progress reconciliation
- A title with only its last minute or so left counts as finished: the swipe, the menus and the buttons offer to mark it, and it shows as finished
- **Mär playlists**: playlists of your own that mix titles from different sources, travelling between your devices as their own record (iCloud or your own sync service)
- **Bookmarks** per book (position + title) synced through the Audiobookshelf bookmark API, created from the player, with offline queueing: bookmarks created or deleted without a connection are sent automatically once it returns
- Settings screen: sources and per-service sync in one tab-independent place, the Sync page (iCloud, or a Mär sync service of your own), skip interval, default playback speed for new books, **Smart Rewind** (resume a little earlier after longer pauses), **auto-play the next unfinished book of a series**, appearance override (system/light/dark), Wi-Fi download warning toggle, storage management, notifications, listening statistics, and the app version. Most of these choices travel between your devices; what stays with each device is the iCloud switch itself, the cellular warning, drive mode, the sleep timer and the tab you left open
- **Drive mode**: a big-button full-screen layout for the car mount, manual entry, or automatic entry when your chosen car audio route connects while Mär has a player loaded (no extra permissions); screen stays awake, Siri shortcut included
- **Listening History**: a per-person podcast listening history that survives unsubscribing and feed rotation, and a Listening History for books and for music as the last row of their tabs: the books you finished and the songs you played (once half of a song or four minutes have played), newest first; a row opens its book or the song's album. It stays on this device
- The app restarts on the **last selected tab**, and a temporarily unreachable server never throws you off your tab
- **Siri & Shortcuts**: “Continue listening in Mär”, “Play *book* in Mär” (book names come from the library rows in the app's database) and “Mär drive mode”, plus a home-screen quick action that resumes the last played book
- **CarPlay**: audiobook tabs (Continue Listening / Downloads / Library), plus a Podcasts tab and a Music tab once those sources are set up, each with cover thumbnails and the system Now Playing screen, sharing the phone's playback session. It works on a cold start in the car, falling back to the offline cache; testable in the simulator out of the box, real cars need Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay)
- Adaptive light and dark design with a **dark-gray brand accent**; each media type carries its own color on the tab selector: audiobooks orange, podcasts purple, music red, radio cyan. The Liquid Glass chrome (mini player, search, toolbar buttons) takes a soft pastel wash of the current cover color in light mode, and the mini player stays in place while the next title loads
- Performance: grid cells decode a small derived thumbnail instead of the full cover, for smooth scrolling and far less memory with large libraries; large covers are brought to their display size before the app holds them, two at a time, and a tile that left the screen no longer loads its cover; the book list is fetched in Audiobookshelf’s minified format; what the app keeps between sync rounds (positions, choices, playlists and statistics of your other devices) lives in its database row by row, so a save while something plays writes only what changed
- **Accessibility**: full Dynamic Type support up to the accessibility text sizes: control rows reflow to a two-column grid, fixed-width tiles gain lines, and hard-coded metrics scale via `@ScaledMetric`; VoiceOver labels on all controls and 44 pt tap targets; verified across device sizes from the 375 pt class to iPad in both orientations
- Hardening: free-space check before downloads start, magic-byte container detection with automatic file-extension repair (unit-tested), automatic recovery when a track fails mid-playback instead of silent stalling, a title that cannot load stops with a short note and loads again on the next tap on play (and by itself, without starting, when the network returns), a downloaded file that cannot be read plays on from the server at the same point and is fetched again, a track that arrives with fewer bytes than the server names counts as a failed download, not a finished one, a download that ends at the same byte three times in a row fails with a note instead of starting over, a stream that stops delivering shows “Waiting for the network…” and never stops playback, a list that could not load says so with Retry instead of showing an empty result, VoiceOver labels on all transport controls

## Podcasts

Version 2.0 makes Mär a full **podcast client** alongside audiobooks. Podcasts are a separate media type behind the same provider protocol, so audiobook playback and sync stay untouched; a dedicated podcast tab is on by default and can be switched off with the other tabs under Settings, and without subscriptions it shows its own empty state.

- **Subscription sources, reconciled:** local **RSS** feeds, opt-in **Audiobookshelf** podcast libraries, a self-hosted **gpodder/mygpo** server (e.g. [oPodSync](https://github.com/kd2org/opodsync)) as an equal backend next to iCloud, a Mär sync service and ABS, and the channel list of a **Pinchflat** server as its own group. Subscriptions, unsubscribes, and play state are kept in one clean, reconciled state across them; a robust unsubscribe removes a feed from every source at once
- **Import from other podcast apps, with your listening states:** Apple Podcasts (the `MTLibrary.sqlite` copied from a Mac), Overcast (its extended OPML export), AntennaPod (its database export), Pocket Casts (your own account, e-mail and password, read once, nothing stored) and plain OPML. Subscriptions and listening states come along under one rule: where both sides carry a moment, the newer state wins; a state without a moment only fills gaps; a finished episode is never taken back; an archived episode counts as finished. Every import shows a preview first and names what it could not match
- **Export with listening states:** the OPML export writes your positions and played marks in the extended format Overcast reads, with a `guid` per episode, so Mär reads its own file back complete on another device; premium feeds stay out together with their states
- **Apple-Podcasts-style home:** a “Keep Listening” row of rich featured cards (remaining time · last played · chapter), usage-driven recommendations, the up-next queue, a premium row, downloaded episodes, and a “Subscriptions” show grid whose red badge counts all unplayed episodes, as Apple Podcasts and Pocket Casts do; Settings → Podcasts offers “new since last played” or off instead
- **Usage-driven recommendations:** language-aware and themed from your own library and listening time, expanded by author/publisher and round-robin mixed so no single publisher dominates; each suggestion says which of your shows it came from, and shows you heard without following them get a "Co-listened" row of their own
- **Per-show settings:** inbox mode, auto-download of new episodes, and new-episode notifications per show
- **Premium feeds** via per-feed HTTP Basic auth, stored in the keychain
- **Rich metadata** from RSS / Podcasting 2.0 and the PodcastIndex API: seasons, episode type, explicit flag, guests/persons, transcripts, funding links, categories
- **Background refresh** (`BGAppRefreshTask`) with one notification per refresh that names the shows with new episodes, offline downloads, a play queue, chapters, transcripts in the player, high-resolution feed covers, CarPlay, and the home-screen widgets “Up Next” and “Continue Listening”, which show books, music and episodes
- Listening-history bridging between RSS and ABS podcast episodes (shared progress, optional server push)
- **Chapters and ads, one honest limit:** chapters are read from `podcast:chapters` only (not from PSC tags in the feed, not from ID3 `CHAP` frames in the file). Mär does no ad detection. Shows that insert ads at download time serve a different file to each device, so the listening position of one episode can differ between your devices by the length of the inserted ads; the app cannot tell an ad from the episode

## Music

Version 2.1 adds **music** as a third media type, for **Subsonic / OpenSubsonic**-compatible servers (Navidrome, gonic, Airsonic). Like podcasts it sits behind the same provider protocol, so audiobook and podcast playback stay untouched; the Music tab is on from the start with the free netlabel and old-record rows (and Jamendo once a key is set), and your own server joins it once it is set up in the Music area of the source map in Settings.

- **Media-type-specific browsing** (not the audiobook grid): full-size playlist cards with a real cover mosaic on top, a grouped library list (Artists · Albums · Songs · Playlists · Genres · Downloads), "Recently Played" / "Recently Added" shelves, and the Listening History as the last row. A long press on an album or a playlist offers the same menu everywhere. An album is one multi-track item: tapping a track plays the whole album from that point through the same player as everything else.
- **Playlists**: create, rename, and delete server playlists; add songs or whole albums from any context menu ("Add to Playlist", with a new-playlist flow); remove rows index-precisely. Continue-listening works for playlists AND albums (server bookmarks on Subsonic, cross-device).
- **Jellyfin** as a second music backend behind the same surface: albums, artists, playlists, search, lyrics, favorites. With a Subsonic server and Jellyfin both set up, Music asks both for every list and plays each title from its own server. In daily use.
- **Jellyfin audiobooks (measured against Jellyfin 12)**: a library with `CollectionType: books` shows up as an audiobook library, and its entries play with a real listening position that travels to the server and back. Jellyfin 12 lists every file of an audiobook folder as its own entry; Mär folds the files of one folder that carry the same album tag into **one book**, in track order, with one position that carries across files, restarts and your other device. Files with different tags, or without one, stay separate books, so a folder that holds several single-file books keeps them apart. **One measured limit, and it is the server's:** there are **no chapters** (Jellyfin generates none for `AudioBook`). The listening position travels over `UserData`, not over playback sessions; the session route was measured not to persist anything. Jellyfin 12 also turned off the older ways apps identified their requests; Mär identifies every request the way version 12 expects, in the request header and in the stream and cover links, a form older servers accept too.
- **Booksonic mode**: mark a Subsonic source as audiobooks and its albums become books (chapters, progress, continue-listening) in the audiobook tab. The listening position of such a book travels between your devices through the server's own bookmarks: the device that plays writes one, the other starts there.
- **Artist pages** (OpenSubsonic): artist image and biography, top songs (tap to play), and similar artists limited to those that actually exist in your own library. All best-effort: a server without a metadata agent simply shows fewer sections.
- **Album detail**: notes, year · genre, a favorite in the page's menu (a filled heart under the title), and offline download of the whole album. A high-resolution front cover is fetched from the **Cover Art Archive** when the album carries a MusicBrainz ID (respecting its User-Agent and 1 request/second policy).
- **Lyrics in the player**: server-first (`getLyricsBySongId`), with the open **LRCLIB** service as a fallback (a ±5 s duration check guards its fuzzy matching); synced lyrics highlight the current line and follow playback with tap-to-seek, unsynced lyrics render as static text. Results, including negative hits, are cached on disk, so the button and panel stay instant and work offline.
- **Favorites** (star / unstar) and **scrobble on play**: the server's own play counts, and Last.fm / ListenBrainz when the server forwards scrobbles.
- No listening position per song on the server; albums and playlists resume through the server's bookmarks (see Playlists above). Playback, downloads, and a CarPlay music tab use the shared core. The metadata endpoints are verified against the OpenSubsonic extensions where available.

## Radio

Mär also plays **internet radio**, a fourth media type behind the same provider protocol. The Radio tab is on from the start; its switch, “Internet radio”, sits in the Radio area of the source map in Settings.

- **Two sources:** the open **[Radio Browser](https://www.radio-browser.info/)** catalog (searchable, no account) and your **own stream URLs** (e.g. an AzuraCast mount) added by hand. Codec/bitrate variants of the same station are folded to a single result, with a quality picker on the station page and in the live player.
- **National & regional discovery**: popular stations of your own country plus a state/region picker; station detail pages (homepage, bitrate, codec, tags, similar stations, and every stream with format, bitrate and the server it comes from) via the context menu.
- **Honest live abstraction:** a live stream has no duration, no seek, no progress, and no download, so the player switches to a live layout: a LIVE marker instead of a scrubber, play/pause only, and a clock-based sleep timer. None of the progress machinery runs, and radio never enters the up-next queue.
- **ICY now-playing:** the current song from the stream's ICY metadata shows in the player (under the station name) and on the lock screen.
- **Favorites, your own stations, and a recent ring**, travelling between your devices with your other choices (through iCloud or your own sync service, one statement per station; deleting one removes it on the other device too); a station-colored artwork placeholder (with the station favicon when the stream ships one, or a logo from Wikidata / Wikimedia Commons when that source is on) is shared between the rows and the player, so it never upscales a tiny favicon on the big player. While a song with artist and title plays, the player and the lock screen show its cover from MusicBrainz / Cover Art Archive when one is found, and the station's artwork otherwise.

## Works with

Mär talks to servers through their standard APIs, so it works with more than one implementation of each. "Verified" stands only where someone has used the app against that server; "protocol-probed" means a probe ran against the server's API with the result stated, and the app itself has not been used with it yet. No compatibility promises for servers that haven't been tried.

- **Audiobookshelf**: audiobooks and podcasts (verified, daily use).
- **Navidrome** (Subsonic/OpenSubsonic): verified, daily use plus an automated 9/9 protocol probe (ping, artists, albums, search, cover art, streaming, playlists). Navidrome 0.64 gives songs, playlists and, in older libraries, albums new ids; Mär reads the version the server reports, speaks to it in the ids it expects, and after the server's update moves what it keeps on the device to the new ids once.
- **oPodSync** (gpodder/mygpo): verified, including the device registration stricter servers require.
- **Jellyfin**: verified, music in daily use; audiobooks measured against Jellyfin 12 on 10 September 2026: a library with `CollectionType: books` shows up as an audiobook library, the files of one folder with the same album tag are one book, and its listening position travels through `UserData`. One limit is the server's: there are no chapters. Works with Jellyfin 12 and with older servers.
- **Pinchflat**: verified end-to-end against a live instance (12/12 real-feed probe): connect with server address + route token (+ optional Basic Auth), the channel list (`/sources/opml`) mirrors as its own group, new/removed channels follow the server, per-channel hide as opt-out, provenance shown as "YouTube". Credentials live in the keychain; the mirrored group stays out of gpodder sync (each device mirrors its own).
- **RSS / Podcasting 2.0** feeds, the **PodcastIndex** directory, and the open **Radio Browser** catalog for stations.
- **gonic** (v0.22.0): verified from the app against a test instance (sign-in, library, search, cover art, playback), plus the 9/9 Subsonic protocol probe (wave 3).
- **Airsonic Advanced**: protocol-probed, 9/9 endpoints once the probe negotiated the API version (wave 3). Mär negotiates the version itself since July; not yet confirmed from the app. An account whose password is stored only as bcrypt or argon2 answers 41 to the token sign-in; Mär shows that reason and never falls back to sending the password in clear text (set the password again in Airsonic, or choose a decodable encoder there).
- **PodFetch**: protocol-probed as a gpodder server (wave 2): login and device registration work; two deviations remain open, the subscription list arrives as an object instead of a list and episode actions answer 400. Mär's gpodder sync depends on both, so treat it as not yet working until tested.
- **Funkwhale** (1.2.10): protocol-probed (wave 2): ping, search and streaming work; needs a separate Subsonic token as the password; numeric ids and JSON cover answers are handled since July. Not yet used from the app.
- **Booksonic** (Air 2201.1.0): protocol-probed by hand at API 1.15.0 (6 endpoints); Mär negotiates the older version since July. Not yet used from the app.
- Deliberately **not** probed: **Podsync** (needs the user's own Google API key, out of scope for a probe) and **ytdl-sub** (produces no RSS; not part of this family).

Only rows the compatibility matrix actually covers are claimed as verified; everything else is "should work" at best. Source of truth for the verified rows is the compatibility matrix in the delivery repo.

## Core sync rule

This is the heart of the app. A user-triggered seek action (scrubber, chapter jump, skip buttons, or lock screen control) is treated as intentional and synced immediately, even backwards. A warning dialog only appears if progress drops by more than 120 seconds **without user action**, for example due to a faulty client reset. If the user cancels, playback jumps back to the last stored position. The lock screen has no palm detection, so a series of more than five skips within four seconds there is not carried out further: the app asks once whether the whole series was meant.

When switching devices, the app checks the server before each playback start and waits up to 1.5 seconds for its answer; a server that does not answer in time does not hold the player, and the start goes ahead from the position on the device. The entry with the newer timestamp wins: if another device wrote last, its position is adopted, even if it is **further back** (e.g. after deliberately rewinding there). On older servers without a timestamp, only a further-ahead server position is adopted. True simultaneous listening on two devices is not covered; in that case, the last writer wins.

Every progress write sends the current time and the finished status together, and the duration and progress whenever the duration is known, rather than a partial update; a partial update leaves the server to guess what to do with the fields it wasn't given, which previously caused real progress loss when only the finished flag was toggled. Without a known duration (a multi-file book the server gave none for) the app leaves duration and progress out, because a progress of 0 would overwrite the server's.

## Intentionally not included

Multi-user support, metadata editing, and server/library administration. Also not built (today): an equalizer and an Apple Watch app.

## Requirements

- Xcode with an iOS 26 SDK or newer (needed to build the app, which uses Apple's Liquid Glass API where the system has it)
- Deployment target **iOS/iPadOS 18.0** (minimum runtime version); on iOS 18 to 25 the glass surfaces fall back to the system material
- A source of audio, but **no server is required to start**:
  - you can **begin without any server** and use radio, podcasts (RSS), the open catalogs and imported local files right away
  - **Audiobookshelf** for audiobooks and podcasts, with your account credentials or an API token
  - and/or a **Subsonic/OpenSubsonic**-compatible music server (Navidrome, gonic, Airsonic) for the Music tab
  - **internet radio** needs no server: the public Radio Browser catalog, plus any of your own stream URLs
  - podcast subscriptions can additionally sync through a self-hosted **gpodder/oPodSync** server (optional; iCloud, a Mär sync service and Audiobookshelf are the other backends)
  - optionally a **Mär sync service** you host yourself ([maer-sync](https://codeberg.org/LzS/maer-sync), one SQLite file, only behind TLS on your own host; the deployed build is a single statically linked Rust binary, the Python implementation of the same contract stays in the tree beside it) so positions, statistics, playlists and choices travel between your devices without iCloud
- An Apple ID for signing; with a free Apple ID, remove the capabilities a free team cannot sign first (see step 2 below)

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). Up to v2.1 Mär was offered under
the MIT license; from this commit on GPL-3.0-or-later applies. LICENSE files
in older history are historical artifacts.

Mär is GPL-3.0-or-later. Additional terms under GPL-3.0 section 7 apply: an additional
permission for distribution through application distribution channels, and a
reservation of the name and icon: see
[LICENSE-ADDITIONAL-TERMS](LICENSE-ADDITIONAL-TERMS). For distribution through
the App Store a custom end-user agreement applies instead of Apple's standard
one: [docs/EULA.md](docs/EULA.md). The source of every released version stays
available at <https://codeberg.org/LzS/maer>.

---

## 1. Sign-in options

The app signs in either with your Audiobookshelf **username and password** (the default: it exchanges them for a token via `/login` and stores only the token in the keychain) or directly with an **API token**.

Note for servers on the new JWT authentication (v2.26.0+): the password login receives a short-lived access token there, so the session can expire. The app keeps the token, shows the state at the Audiobookshelf source and checks again by itself; only when the server still refuses it does the app offer a new sign-in, prefilled, and it deletes nothing on its own. On such servers an API key is the more durable choice.

How to find your token:

- **Older server versions:** Web interface → Settings → Users → select your account → the token is displayed.
- **Newer server versions:** Web interface → Settings → API Keys → create a new key.

If you are not sure which variant your server uses, try both. One of these paths will exist.

---

## 2. Build & install

The repository ships the complete Xcode project; nothing needs to be assembled.
**Mär builds without any API keys** (two optional app keys for Jamendo and
PodcastIndex are read from `Config/AppKeys.local.xcconfig` if that file exists;
a key entered in the app's settings comes first. Without any key the Jamendo
rows stay away and the podcast search uses Apple's directory) and it has **no
third-party dependencies**: no package manager step, nothing to resolve.

1. Clone the repo and open **`Maer.xcodeproj`** (Xcode with an iOS 26 SDK or newer).
2. **Signing** (target `Maer` → Signing & Capabilities):
   - **Team:** your Apple ID. `Maer.entitlements` asks for CarPlay audio, push notifications, iCloud (CloudKit container and key-value store) and an App Group. A free team cannot sign CarPlay, push or iCloud: with a free Apple ID, remove those three capabilities first. The app then syncs nothing over iCloud.
   - **Bundle Identifier:** change it to something unique, e.g. `de.yourname.maer`, on BOTH targets (`Maer` and `MaerWidgetsExtension`; the widget ID must stay a child of the app ID, e.g. `de.yourname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift`, set the `service` constant to the same bundle identifier.
   - **App Group:** replace the group identifier in both targets' `.entitlements` files and in `Sources/Models/WidgetShared.swift` with one of your own (e.g. `group.de.yourname.maer`); a group registered to someone else's team will not sign.
   - **iCloud container** (paid team only): replace `iCloud.fm.maer.app` in `Maer.entitlements` and in `Sources/Networking/CloudZoneDatabase.swift` with a container of your own.
3. Connect your iPhone, select it as the run destination (background audio is far more reliable to test on a real device than in the simulator), press ▶.
4. On the iPhone, trust your Apple ID once under **Settings → General → VPN & Device Management** if asked.

Background audio, the widget extension target, the CarPlay scene, and iPhone/iPad support are already configured in the project.

**Free Apple ID without the Developer Program:** with the three capabilities removed, the app runs for 7 days per install, then rebuild once via Xcode. **CarPlay** needs Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay, paid account) to sign the capability for a device and to use it in a real car; the CarPlay simulator (`I/O → External Displays → CarPlay`) works without it.

## 3. Log in inside the app

- Server: `your-server.example.com`; `https://` is added automatically
- Then either username + password, or an API token from step 1

---

## iPad support

iPhone and iPad are both enabled in the project. The library grid adapts automatically to the available width (more columns on iPad, even more in landscape) and recalculates cleanly on every rotation. On iPhone portrait, the mini-player drops its skip buttons to leave more room for the title and keeps AirPlay; elsewhere the skip buttons appear when the bar is at least 360 points wide, measured on the window, not the device.

On the iPhone Duo the tabs, the search and the settings button stand in a side column, folded and open; the full player and the search use it too. Open, the detail pages divide at the fold into two columns, and the settings stand in two columns where the page is wide enough.

## Source layout

The tree below is a selection, not the whole repository (`Sources/` holds 580 files; `tools/` is not part of the Xcode project, and the sync service has its own repository). It names the layers that carry the app today; every line describes the file it names.

```text
Sources/
├── MaerApp.swift                   Entry point + AppDelegate for background download events;
│                                   waits for every row chain and checkpoints the database
│                                   on background and termination
├── AppSession.swift                Process-wide session (player coordinator, library, providers;
│                                   shared with CarPlay)
├── AppShortcuts.swift              Siri App Intents (continue listening, play a specific book,
│                                   drive mode; the books come from the library rows)
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
│   ├── PlaybackContext.swift       The rest of a collection start (one row), not the queue
│   └── PodcastImport.swift         Apple Podcasts, Overcast, AntennaPod and OPML import
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  CarPlay tabs (audiobooks + podcasts + music) + Now Playing
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
│   └── PodcastAutoDownloadRules.swift  Pure: what the automatic download may clean up
├── Networking/
│   ├── APIClient.swift             Audiobookshelf HTTP calls
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
│   ├── GlobalSearchModel.swift, SearchDoor.swift   Cross-source search and its one door
│   ├── LibraryViewModel.swift      Loads book list and progress, sorting, series grouping,
│   │                               offline cache as rows
│   ├── PlayerCoordinator.swift     Keeps the active session alive across navigation,
│   │                               offline-aware, basis for the mini-player
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
    ├── PodcastsView.swift          Podcast home (continue, recommendations, queue, shelves)
    ├── PodcastSourceView.swift     Add/import podcasts and pick subscription sources
    ├── Podcasts/                   Show, episode, queue, discover, per-show settings, cards
    ├── Music/                      Music home, album, artists, playlists, lyrics panel
    └── Radio/                      Radio tab, station rows, shared radio artwork
```

**Mini-player architecture note:** `PlayerCoordinator` lives in `AppSession` (process-wide, shared with CarPlay) and survives navigation. Playback is not stopped when leaving the player screen or when the mini-player is temporarily hidden; it only stops when explicitly opening a different book.

## Endpoints

Audiobookshelf endpoints used (complete, measured on `Sources/Networking/APIClient.swift`):

| Purpose | Endpoint |
|---|---|
| Libraries, one library | `GET /api/libraries`, `GET /api/libraries/{id}` |
| Book list (progressive paging) | `GET /api/libraries/{id}/items?minified=1&limit=&page=` |
| Continue / Recently-Added shelves | `GET /api/libraries/{id}/personalized` |
| Book details, chapters and progress | `GET /api/items/{id}?expanded=1` |
| Write progress (book, podcast episode) | `PATCH /api/me/progress/{itemId}`, `PATCH /api/me/progress/{itemId}/{episodeId}` |
| Progress for the whole library | `GET /api/me` |
| Password sign-in | `POST /login` |
| Search (books/authors/series) | `GET /api/libraries/{id}/search?q=` |
| Bookmarks | `GET /api/me`, `POST /api/me/item/{id}/bookmark`, `DELETE /api/me/item/{id}/bookmark/{time}` |
| Cover, author image | `GET /api/items/{id}/cover?width=400&token=...` (grids, rows, CarPlay, widget), `GET /api/items/{id}/cover?raw=1&token=...` (book page, full player, lock screen), `GET /api/authors/{id}/image?token=...` |
| Podcast libraries (opt-in source) | `POST /api/podcasts`, `POST /api/podcasts/feed`, `POST /api/podcasts/{id}/download-episodes` |
| A show's cover, removing a show (needs delete rights) | `POST /api/items/{id}/cover`, `DELETE /api/items/{id}` |
| Upload of a local file to the server | `POST /api/upload` |
| Audio stream | direct `contentUrl` from the track data, with `Authorization: Bearer` header |

gpodder/mygpo endpoints used (complete, `GPodderClient.swift`): `POST /api/2/auth/{user}/login.json`, `GET /api/2/devices/{user}.json` and `POST /api/2/devices/{user}/{device}.json` (the device registration stricter servers require), `GET/POST /api/2/subscriptions/{user}/{device}.json`, `GET/POST /api/2/episodes/{user}.json`.

Podcasts additionally talk to external **RSS feeds**, the **PodcastIndex** API and **iTunes** charts (discovery/metadata, optional key), your self-hosted **gpodder/mygpo** server, and a **Pinchflat** instance's `/sources/opml` for its channel list.

Music talks to your **Subsonic/OpenSubsonic** server (complete, `SubsonicClient.swift`: `ping`, `getMusicFolders`, `getAlbumList2`, `getAlbum`, `getAlbumInfo2`, `getArtists`, `getArtist`, `getArtistInfo2`, `getTopSongs`, `getSong`, `getRandomSongs`, `getGenres`, `getSongsByGenre`, `getStarred2`, `search3`, `getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getBookmarks`, `createBookmark`, `deleteBookmark`, `getLyricsBySongId`, `getScanStatus`, `stream`, `getCoverArt`, `scrobble`, `star`, `unstar`), or your **Jellyfin** server (complete, `JellyfinClient.swift`: `Users/AuthenticateByName`, `Users/{id}/Views`, `Users/{id}/Items`, `Users/{id}/Items/{id}`, `Users/{id}/FavoriteItems/{id}`, `Users/{id}/PlayedItems/{id}`, `UserItems/{id}/UserData`, `Items/{id}/Images/Primary`, `Artists`, `MusicGenres`, `Audio/{id}/universal`, `Audio/{id}/Lyrics`, `Playlists`, `Playlists/{id}`, `Playlists/{id}/Items`, `Items/{id}`), the **Cover Art Archive** (high-resolution covers via MusicBrainz ID), and **LRCLIB** (open lyrics fallback).

A Mär sync service, when set up, is reached over `GET /v2/key` (the service's key), `POST /v1/session` (the sealed session the other requests travel in), `GET /v1/health`, `GET /v1/salt`, `POST /v1/password`, `POST /v1/token`, `GET`/`PUT /v1/doc/{kind}`, `GET /v1/docs/{kind}` and the changes socket `/v1/changes`, all described in the service's own repository, [maer-sync](https://codeberg.org/LzS/maer-sync), whose README is a setup guide. **The wire itself is written down on both sides**: `docs/maer-sync-contract.md` here and `CONTRACT.md` there are the same file, and each repository holds a fence against its own code.

Radio uses the open **[Radio Browser](https://www.radio-browser.info/)** catalog (`/json/stations/search`, mirror fallback across `de1`/`at1`/`nl1`) and plays your own stream URLs directly; the live song comes from the stream's own ICY metadata.

## About this project

Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable), Mistral (Codestral and Mistral Large, via Mistral's API) for reviews, plus locally hosted open-weight models (qwen3, devstral and OpenAI's open gpt-oss weights) run via Ollama for tooling.
