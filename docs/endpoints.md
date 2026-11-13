# Mär: endpoints

Back to the [README](../README.md) · [Deutsch](endpoints.de.md)

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
| Password sign-in | `POST /login` with `x-return-tokens: true` |
| Sign-in methods the server offers | `GET /status` |
| Single sign-on (OpenID Connect, with PKCE) | `GET /auth/openid?…&redirect_uri=audiobookshelf://oauth` in the system's sign-in window, then `GET /auth/openid/callback?state=&code=&code_verifier=` |
| Search (books/authors/series) | `GET /api/libraries/{id}/search?q=` |
| Bookmarks | `GET /api/me`, `POST /api/me/item/{id}/bookmark`, `DELETE /api/me/item/{id}/bookmark/{time}` |
| Cover, author image | `GET /api/items/{id}/cover?width=400&token=...` (grids, rows, CarPlay, widget), `GET /api/items/{id}/cover?raw=1&token=...` (book page, full player, lock screen), `GET /api/authors/{id}/image?token=...` |
| Podcast libraries (opt-in source) | `POST /api/podcasts`, `POST /api/podcasts/feed`, `POST /api/podcasts/{id}/download-episodes` |
| A show's cover, removing a show (needs delete rights) | `POST /api/items/{id}/cover`, `DELETE /api/items/{id}` |
| Upload of a local file to the server | `POST /api/upload` |
| Audio stream | direct `contentUrl` from the track data; the end of its redirects is asked once with `Range: bytes=0-0`, and the `Authorization: Bearer` header goes only to an end on the server itself |

gpodder/mygpo endpoints used (complete, `GPodderClient.swift`): `POST /api/2/auth/{user}/login.json`, `GET /api/2/devices/{user}.json` and `POST /api/2/devices/{user}/{device}.json` (the device registration stricter servers require), `GET/POST /api/2/subscriptions/{user}/{device}.json`, `GET/POST /api/2/episodes/{user}.json`.

Podcasts additionally talk to external **RSS feeds**, the **PodcastIndex** API and **iTunes** charts (discovery/metadata, optional key), your self-hosted **gpodder/mygpo** server, and a **Pinchflat** instance's `/sources/opml` for its channel list.

Music talks to your **Subsonic/OpenSubsonic** server (complete, `SubsonicClient.swift`: `ping`, `getMusicFolders`, `getAlbumList2`, `getAlbum`, `getAlbumInfo2`, `getArtists`, `getArtist`, `getArtistInfo2`, `getTopSongs`, `getSong`, `getRandomSongs`, `getGenres`, `getSongsByGenre`, `getStarred2`, `search3`, `getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getBookmarks`, `createBookmark`, `deleteBookmark`, `getLyricsBySongId`, `getScanStatus`, `stream`, `getCoverArt`, `scrobble`, `star`, `unstar`), or your **Jellyfin** server (complete, `JellyfinClient.swift`: `Users/AuthenticateByName`, `Users/{id}/Views`, `Users/{id}/Items`, `Users/{id}/Items/{id}`, `Users/{id}/FavoriteItems/{id}`, `Users/{id}/PlayedItems/{id}`, `UserItems/{id}/UserData`, `Items/{id}/Images/Primary`, `Artists`, `MusicGenres`, `Audio/{id}/universal`, `Audio/{id}/Lyrics`, `Playlists`, `Playlists/{id}`, `Playlists/{id}/Items`, `Items/{id}`), the **Cover Art Archive** (high-resolution covers via MusicBrainz ID), and **LRCLIB** (open lyrics fallback).

A Mär sync service, when set up, is reached over `GET /v2/key` (the service's key), `POST /v1/session` (the sealed session the other requests travel in), `GET /v1/health`, `GET /v1/salt`, `POST /v1/password`, `POST /v1/token`, `GET`/`PUT /v1/doc/{kind}`, `GET /v1/docs/{kind}` and the changes socket `/v1/changes`, all described in the service's own repository, [maer-sync](https://github.com/maer-lzs/maer-sync), whose README is a setup guide. **The wire itself is written down on both sides**: `docs/maer-sync-contract.md` here and `CONTRACT.md` there are the same file, and each repository holds a fence against its own code.

Radio uses the open **[Radio Browser](https://www.radio-browser.info/)** catalog (`/json/stations/search`, mirror fallback across `de1`/`at1`/`nl1`) and plays your own stream URLs directly; the live song comes from the stream's own ICY metadata.
