<p align="center">
  <img src="docs/logo.png" alt="Mär app icon" width="128" height="128">
</p>

# Mär

A lightweight, open-source iOS/iPadOS client for **self-hosted audio**: audiobooks, podcasts, music, and internet radio in one app, with one design language and one player.

Mär is **server-first and offline-first**: your library, metadata, covers, and progress live on your own servers and reach the app over **open, standard APIs that need no client-side API keys**: [Audiobookshelf](https://www.audiobookshelf.org/), Subsonic/OpenSubsonic, Jellyfin, gpodder/mygpo, plain RSS (including the channel feeds a Pinchflat instance mirrors), and the open Radio Browser catalog. Its foundation is **reliable playback progress sync** across devices, without accidentally resetting a book to 0, including while fully offline.

> „Mär“ is an old German word for a tale or story, fitting for an audio player. The Xcode project is `Maer.xcodeproj`; “Mär” with the umlaut is the display name.

Mär started as a private replacement for a client that regularly lost playback progress when switching devices. It has since grown into a universal client for the self-hosted, open-source audio ecosystem, built on a provider architecture, deliberately focused: no multi-user support, no server administration, just listening and keeping progress reliably in sync, online or off.

> **Note:** This is a private hobby project without warranty. It is not affiliated with the Audiobookshelf project.

**Home:** <https://maer.fm> · **Source:** <https://github.com/maer-lzs/maer> · **Community:** <https://www.reddit.com/r/maer_fm/>

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

One app, one player and one design for four kinds of audio. Every feature in detail: [docs/features.md](docs/features.md).

### Audiobooks

- Audiobookshelf libraries as an adaptive cover grid, with series, authors, filters and sorting that stay as you left them
- Books split across several files play as one, with chapters, bookmarks and a sleep timer
- Download whole books for offline listening; the library stays usable when the server is out of reach
- Free audiobooks from LibriVox, Project Gutenberg and the Internet Archive, without a server
- Booksonic and Jellyfin audiobook libraries in the same tab

### Podcasts

- Subscribe by RSS, Audiobookshelf podcast libraries or a gpodder server, all reconciled into one list
- Import from Apple Podcasts, Overcast, AntennaPod, Pocket Casts and OPML, with your listening states; export them again
- Up Next, routines, per-show settings, new-episode notifications, chapters, transcripts and premium feeds
- Usage-driven recommendations from your own library and listening time

### Music

- Subsonic and OpenSubsonic servers (Navidrome, gonic, Airsonic) and Jellyfin, side by side
- Playlists you can create and edit, artist pages, album downloads, favorites and scrobbling
- Lyrics in the player, from the server or from LRCLIB
- Free music from Jamendo and the netlabels of the Internet Archive

### Radio

- The open Radio Browser catalog and your own stream URLs
- Stations of your country and region, favorites and recently played stations that travel between your devices
- The current song from the stream, in the player and on the lock screen

### Everywhere

- One search across all sources, a Home tab that mixes all media, and Mär playlists across sources
- Progress that never jumps back to the start, across devices and offline
- CarPlay, widgets, Siri and Shortcuts, lock screen and Dynamic Island
- Share a podcast, episode, station, free audiobook or Jamendo track as a link
- iPhone, iPad and the iPhone Duo, Dynamic Type and VoiceOver

## Works with

Mär talks to servers through their standard APIs:

- **Audiobookshelf** for audiobooks and podcasts
- **Navidrome**, **gonic** and other Subsonic or OpenSubsonic servers, and **Jellyfin**, for music (Jellyfin also for audiobooks)
- **oPodSync** and other gpodder servers for podcast subscriptions
- **Pinchflat** channel feeds, any **RSS** feed, the **PodcastIndex** directory and the **Radio Browser** catalog

Which servers were verified from the app and which only by a protocol probe: [docs/features.md](docs/features.md#works-with).

## Privacy & Data Security

Mär has no account, no service of its own, no tracking and no third-party code. Your library, positions and logins stay on your device and on your own servers. Listening positions, choices and playlists travel between your devices through iCloud, which you can turn off, or through a Mär sync service you host yourself. Every external service that is not your own server has its own switch in the settings.

The privacy policy: [maer.fm/privacy](https://maer.fm/privacy). What leaves the device, statement by statement: [docs/privacy.md](docs/privacy.md).

## Requirements

- Xcode with an iOS 26 SDK or newer (needed to build the app, which uses Apple's Liquid Glass API where the system has it)
- Deployment target **iOS/iPadOS 18.0** (minimum runtime version); on iOS 18 to 25 the glass surfaces fall back to the system material
- A source of audio, but **no server is required to start**:
  - you can **begin without any server** and use radio, podcasts (RSS), the open catalogs and imported local files right away
  - **Audiobookshelf** for audiobooks and podcasts, with your account credentials or an API token
  - and/or a **Subsonic/OpenSubsonic**-compatible music server (Navidrome, gonic, Airsonic) for the Music tab
  - **internet radio** needs no server: the public Radio Browser catalog, plus any of your own stream URLs
  - podcast subscriptions can additionally sync through a self-hosted **gpodder/oPodSync** server (optional; iCloud, a Mär sync service and Audiobookshelf are the other backends)
  - optionally a **Mär sync service** you host yourself ([maer-sync](https://github.com/maer-lzs/maer-sync), one SQLite file, only behind TLS on your own host; the deployed build is a single statically linked Rust binary, the Python implementation of the same contract stays in the tree beside it) so positions, statistics, playlists and choices travel between your devices without iCloud
- An Apple ID for signing; with a free Apple ID, remove the capabilities a free team cannot sign first (see step 2 below)

## Build & install

The repository ships the complete Xcode project; nothing needs to be assembled.
**Mär builds without any API keys** (two optional app keys for Jamendo and
PodcastIndex are read from `Config/AppKeys.local.xcconfig` if that file exists;
a key entered in the app's settings comes first. Without any key the Jamendo
rows stay away and the podcast search uses Apple's directory) and it has **no
third-party dependencies**: no package manager step, nothing to resolve.

1. Clone the repo and open **`Maer.xcodeproj`** (Xcode with an iOS 26 SDK or newer).
2. **Signing** (target `Maer` → Signing & Capabilities):
   - **Team:** your Apple ID. `Maer.entitlements` asks for CarPlay audio, push notifications, iCloud (CloudKit container and key-value store), Associated Domains (`applinks:maer.fm`, so shared links open in the app) and an App Group. A free team cannot sign CarPlay, push, iCloud or Associated Domains: with a free Apple ID, remove those four capabilities first. The app then syncs nothing over iCloud, and shared links open in the browser.
   - **Associated Domains** (paid team): maer.fm names only this project's app, so on your own build remove the capability, or point it at a domain of your own that serves `site/.well-known/apple-app-site-association` with your app ID.
   - **Bundle Identifier:** change it to something unique, e.g. `de.yourname.maer`, on BOTH targets (`Maer` and `MaerWidgetsExtension`; the widget ID must stay a child of the app ID, e.g. `de.yourname.maer.widgets`)
   - In `Sources/Networking/KeychainStore.swift`, set the `service` constant to the same bundle identifier.
   - **App Group:** replace the group identifier in both targets' `.entitlements` files and in `Sources/Models/WidgetShared.swift` with one of your own (e.g. `group.de.yourname.maer`); a group registered to someone else's team will not sign.
   - **iCloud container** (paid team only): replace `iCloud.fm.maer.app` in `Maer.entitlements` and in `Sources/Networking/CloudZoneDatabase.swift` with a container of your own.
3. Connect your iPhone, select it as the run destination (background audio is far more reliable to test on a real device than in the simulator), press ▶.
4. On the iPhone, trust your Apple ID once under **Settings → General → VPN & Device Management** if asked.

Background audio, the widget extension target, the CarPlay scene, and iPhone/iPad support are already configured in the project.

**Free Apple ID without the Developer Program:** with the four capabilities removed, the app runs for 7 days per install, then rebuild once via Xcode. **CarPlay** needs Apple's CarPlay audio entitlement (developer.apple.com/contact/carplay, paid account) to sign the capability for a device and to use it in a real car. With Xcode 27 CarPlay shows only with an iPhone on a cable, not with a simulator.

## Log in inside the app

- Server: `your-server.example.com`; `https://` is added automatically
- Then either username and password, an API token, or the single sign-on button when your server offers one

Where to find a token and how the sign-in keeps your session: [docs/sync-and-sign-in.md](docs/sync-and-sign-in.md#sign-in-options).

## More documentation

- [Features in detail](docs/features.md), including the list of servers and iPad support
- [Privacy and data security](docs/privacy.md)
- [Sync and sign-in](docs/sync-and-sign-in.md)
- [Source layout](docs/architecture.md)
- [Endpoints](docs/endpoints.md)
- [Changelog](CHANGELOG.md)

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
available at <https://github.com/maer-lzs/maer>.

## About this project

Mär was created with support from AI: Anthropic Claude (Opus, Sonnet and Fable), Mistral (Codestral and Mistral Large, via Mistral's API) for reviews, plus locally hosted open-weight models (qwen3, devstral and OpenAI's open gpt-oss weights) run via Ollama for tooling.
